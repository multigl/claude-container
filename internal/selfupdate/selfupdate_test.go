package selfupdate

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const assetName = "claude-container_linux_amd64"

type releaseServer struct {
	server        *httptest.Server
	authorization string
}

// newReleaseServer serves a latest-release document listing assetNames,
// the asset bytes and a SHA256SUMS file whose line for assetName carries
// sumsDigest.
func newReleaseServer(t *testing.T, tag string, assetNames []string, assetBytes []byte, sumsDigest string) *releaseServer {
	t.Helper()
	release := &releaseServer{}
	mux := http.NewServeMux()
	mux.HandleFunc("/repos/multigl/claude-container/releases/latest", func(writer http.ResponseWriter, request *http.Request) {
		release.authorization = request.Header.Get("Authorization")
		var assets []string
		for _, name := range assetNames {
			assets = append(assets, fmt.Sprintf(`{"name":%q,"browser_download_url":%q}`, name, release.server.URL+"/download/"+name))
		}
		fmt.Fprintf(writer, `{"tag_name":%q,"assets":[%s]}`, tag, strings.Join(assets, ","))
	})
	mux.HandleFunc("/download/"+assetName, func(writer http.ResponseWriter, request *http.Request) {
		writer.Write(assetBytes)
	})
	mux.HandleFunc("/download/SHA256SUMS", func(writer http.ResponseWriter, request *http.Request) {
		fmt.Fprintf(writer, "%s  claude-container_darwin_arm64\n%s  %s\n", strings.Repeat("0", 64), sumsDigest, assetName)
	})
	release.server = httptest.NewServer(mux)
	t.Cleanup(release.server.Close)
	return release
}

func digest(content []byte) string {
	sum := sha256.Sum256(content)
	return hex.EncodeToString(sum[:])
}

func TestLatest(t *testing.T) {
	tests := []struct {
		name              string
		assetNames        []string
		token             string
		wantErrorContains string
		wantAuthorization string
	}{
		{
			name:       "parses the tag and this platform's asset",
			assetNames: []string{"claude-container_darwin_arm64", assetName, "SHA256SUMS"},
		},
		{
			name:              "sends GH_TOKEN as a bearer token",
			assetNames:        []string{assetName, "SHA256SUMS"},
			token:             "secret",
			wantAuthorization: "Bearer secret",
		},
		{
			name:              "missing platform asset",
			assetNames:        []string{"claude-container_darwin_arm64", "SHA256SUMS"},
			wantErrorContains: assetName,
		},
		{
			name:              "missing SHA256SUMS",
			assetNames:        []string{assetName},
			wantErrorContains: "SHA256SUMS",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			release := newReleaseServer(t, "v1.2.3", test.assetNames, nil, "")
			got, err := Latest(release.server.Client(), release.server.URL, "multigl/claude-container", "linux", "amd64", test.token)
			if test.wantErrorContains != "" {
				if err == nil || !strings.Contains(err.Error(), test.wantErrorContains) {
					t.Fatalf("got error %v, want one containing %q", err, test.wantErrorContains)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			want := Release{
				Tag:      "v1.2.3",
				AssetURL: release.server.URL + "/download/" + assetName,
				SumsURL:  release.server.URL + "/download/SHA256SUMS",
			}
			if got != want {
				t.Errorf("got %+v, want %+v", got, want)
			}
			if release.authorization != test.wantAuthorization {
				t.Errorf("Authorization %q, want %q", release.authorization, test.wantAuthorization)
			}
		})
	}
}

func TestLatestServerError(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		http.Error(writer, "boom", http.StatusInternalServerError)
	}))
	t.Cleanup(server.Close)
	if _, err := Latest(server.Client(), server.URL, "multigl/claude-container", "linux", "amd64", ""); err == nil {
		t.Fatal("expected an error for a 500")
	}
}

// installBinary lays out a real file plus a claude-vertex symlink to it, the
// shape install.sh leaves behind.
func installBinary(t *testing.T) (realBinary, symlink string) {
	t.Helper()
	installDirectory := t.TempDir()
	realBinary = filepath.Join(installDirectory, "claude-container")
	if err := os.WriteFile(realBinary, []byte("old binary"), 0o755); err != nil {
		t.Fatal(err)
	}
	symlink = filepath.Join(t.TempDir(), "claude-vertex")
	if err := os.Symlink(realBinary, symlink); err != nil {
		t.Fatal(err)
	}
	return realBinary, symlink
}

func TestApply(t *testing.T) {
	newBinary := []byte("new binary")
	tests := []struct {
		name            string
		sumsDigest      string
		readOnly        bool
		wantErrorIs     error
		wantAnyError    bool
		wantRealContent string
	}{
		{
			name:            "replaces the real file through the symlink",
			sumsDigest:      digest(newBinary),
			wantRealContent: "new binary",
		},
		{
			name:            "checksum mismatch leaves the old file",
			sumsDigest:      strings.Repeat("f", 64),
			wantAnyError:    true,
			wantRealContent: "old binary",
		},
		{
			name:            "read-only install directory",
			sumsDigest:      digest(newBinary),
			readOnly:        true,
			wantErrorIs:     ErrNotWritable,
			wantRealContent: "old binary",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if test.readOnly && os.Geteuid() == 0 {
				t.Skip("root ignores directory permissions")
			}
			release := newReleaseServer(t, "v1.2.3", []string{assetName, "SHA256SUMS"}, newBinary, test.sumsDigest)
			realBinary, symlink := installBinary(t)
			if test.readOnly {
				if err := os.Chmod(filepath.Dir(realBinary), 0o555); err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { os.Chmod(filepath.Dir(realBinary), 0o755) })
			}

			err := Apply(release.server.Client(), Release{
				Tag:      "v1.2.3",
				AssetURL: release.server.URL + "/download/" + assetName,
				SumsURL:  release.server.URL + "/download/SHA256SUMS",
			}, symlink)

			switch {
			case test.wantErrorIs != nil:
				if !errors.Is(err, test.wantErrorIs) {
					t.Fatalf("got %v, want errors.Is %v", err, test.wantErrorIs)
				}
			case test.wantAnyError:
				if err == nil {
					t.Fatal("expected an error")
				}
			case err != nil:
				t.Fatal(err)
			}

			content, readErr := os.ReadFile(realBinary)
			if readErr != nil {
				t.Fatal(readErr)
			}
			if string(content) != test.wantRealContent {
				t.Errorf("real binary holds %q, want %q", content, test.wantRealContent)
			}
			info, statErr := os.Lstat(symlink)
			if statErr != nil || info.Mode()&os.ModeSymlink == 0 {
				t.Errorf("symlink was replaced: %v %v", info, statErr)
			}
			realInfo, statErr := os.Stat(realBinary)
			if statErr != nil {
				t.Fatal(statErr)
			}
			if realInfo.Mode().Perm() != 0o755 {
				t.Errorf("mode %v, want 0755", realInfo.Mode().Perm())
			}
			entries, _ := os.ReadDir(filepath.Dir(realBinary))
			if len(entries) != 1 {
				t.Errorf("temp file left behind: %v", entries)
			}
		})
	}
}
