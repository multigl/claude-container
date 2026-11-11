// Package selfupdate replaces the launcher binary with the latest GitHub
// release asset for the platform it was compiled for.
package selfupdate

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strings"

	"github.com/multigl/claude-container/internal/buildinfo"
)

const (
	DefaultAPIBase = "https://api.github.com"
	sumsName       = "SHA256SUMS"
)

var ErrNotWritable = errors.New("install directory not writable")

type Release struct {
	Tag      string
	AssetURL string
	SumsURL  string
}

// assetFileName is the release asset built for goos/goarch.
func assetFileName(goos, goarch string) string {
	return "claude-container_" + goos + "_" + goarch
}

func get(client *http.Client, address, token string) ([]byte, error) {
	request, err := http.NewRequest(http.MethodGet, address, nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("User-Agent", "claude-container/"+buildinfo.Version)
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	response, err := client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GET %s: %s", address, response.Status)
	}
	return io.ReadAll(response.Body)
}

// Latest queries the latest release of repo and picks out this platform's
// asset and the checksum file.
func Latest(client *http.Client, apiBase, repo, goos, goarch, token string) (Release, error) {
	if apiBase == "" {
		apiBase = DefaultAPIBase
	}
	body, err := get(client, strings.TrimRight(apiBase, "/")+"/repos/"+repo+"/releases/latest", token)
	if err != nil {
		return Release{}, fmt.Errorf("checking the latest release: %w", err)
	}
	var document struct {
		TagName string `json:"tag_name"`
		Assets  []struct {
			Name               string `json:"name"`
			BrowserDownloadURL string `json:"browser_download_url"`
		} `json:"assets"`
	}
	if err := json.Unmarshal(body, &document); err != nil {
		return Release{}, fmt.Errorf("parsing the latest release: %w", err)
	}
	release := Release{Tag: document.TagName}
	wantAsset := assetFileName(goos, goarch)
	for _, asset := range document.Assets {
		switch asset.Name {
		case wantAsset:
			release.AssetURL = asset.BrowserDownloadURL
		case sumsName:
			release.SumsURL = asset.BrowserDownloadURL
		}
	}
	if release.AssetURL == "" {
		return Release{}, fmt.Errorf("release %s has no asset %s", release.Tag, wantAsset)
	}
	if release.SumsURL == "" {
		return Release{}, fmt.Errorf("release %s has no %s", release.Tag, sumsName)
	}
	return release, nil
}

// expectedDigest finds name's line in sha256sum output; a leading '*' marks
// binary mode.
func expectedDigest(sums []byte, name string) (string, error) {
	scanner := bufio.NewScanner(bytes.NewReader(sums))
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) == 2 && strings.TrimPrefix(fields[1], "*") == name {
			return strings.ToLower(fields[0]), nil
		}
	}
	return "", fmt.Errorf("%s has no entry for %s", sumsName, name)
}

// Apply replaces the real file behind executable with the release asset. The
// rename stays in one directory so it is atomic, and goes to the resolved
// file so an install's claude-<flavor> symlinks keep pointing at it.
func Apply(client *http.Client, release Release, executable string) (err error) {
	realBinary, err := filepath.EvalSymlinks(executable)
	if err != nil {
		return err
	}
	assetURL, err := url.Parse(release.AssetURL)
	if err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(realBinary), ".claude-container.update.*")
	if errors.Is(err, fs.ErrPermission) {
		return fmt.Errorf("%w: %v", ErrNotWritable, err)
	}
	if err != nil {
		return err
	}
	defer func() {
		temporary.Close()
		if err != nil {
			os.Remove(temporary.Name())
		}
	}()

	sums, err := get(client, release.SumsURL, "")
	if err != nil {
		return fmt.Errorf("downloading %s: %w", sumsName, err)
	}
	want, err := expectedDigest(sums, path.Base(assetURL.Path))
	if err != nil {
		return err
	}
	asset, err := get(client, release.AssetURL, "")
	if err != nil {
		return fmt.Errorf("downloading the release asset: %w", err)
	}
	sum := sha256.Sum256(asset)
	if got := hex.EncodeToString(sum[:]); got != want {
		return fmt.Errorf("checksum mismatch for %s: got %s, want %s", path.Base(assetURL.Path), got, want)
	}
	if _, err := temporary.Write(asset); err != nil {
		return err
	}
	if err := temporary.Chmod(0o755); err != nil {
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporary.Name(), realBinary)
}
