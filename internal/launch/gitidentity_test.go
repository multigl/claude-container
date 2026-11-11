package launch

import (
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func writeKeyFile(t *testing.T, name, content string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestGitIdentity(t *testing.T) {
	t.Setenv("GIT_CONFIG_GLOBAL", "/dev/null")
	t.Setenv("GIT_CONFIG_NOSYSTEM", "1")
	publicKeyFile := writeKeyFile(t, "id.pub", "ssh-ed25519 AAAAFROMFILE comment\n")
	multilineFile := writeKeyFile(t, "multi.pub", "ssh-ed25519 AAAA\nssh-ed25519 BBBB\n")
	privateKeyFile := writeKeyFile(t, "id", "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n")
	missingPath := "/nope/missing.pub"

	testCases := []struct {
		name         string
		config       map[string]string
		want         string
		wantWarnings []string
	}{
		{
			name:   "identity only",
			config: map[string]string{"user.name": "Ada L", "user.email": "ada@x.io"},
			want:   "[user]\n    name = Ada L\n    email = ada@x.io\n",
		},
		{
			name: "ssh literal key",
			config: map[string]string{"user.name": "A", "user.email": "a@b", "gpg.format": "ssh",
				"user.signingkey": "ssh-ed25519 AAAAKEY", "commit.gpgsign": "true"},
			want: "[user]\n    name = A\n    email = a@b\n    signingkey = ssh-ed25519 AAAAKEY\n[gpg]\n    format = ssh\n[commit]\n    gpgsign = true\n",
		},
		{
			name: "ssh literal key with slash stays literal",
			config: map[string]string{"gpg.format": "ssh", "user.signingkey": "ssh-ed25519 AAAAB3Nz/aC1lZ+DI/25 user@host",
				"commit.gpgsign": "true"},
			want: "[user]\n    signingkey = ssh-ed25519 AAAAB3Nz/aC1lZ+DI/25 user@host\n[gpg]\n    format = ssh\n[commit]\n    gpgsign = true\n",
		},
		{
			name:   "ssh key from readable file, gpgsign false",
			config: map[string]string{"gpg.format": "ssh", "user.signingkey": publicKeyFile, "commit.gpgsign": "false"},
			want:   "[user]\n    signingkey = ssh-ed25519 AAAAFROMFILE comment\n[gpg]\n    format = ssh\n[commit]\n    gpgsign = false\n",
		},
		{
			name:   "ssh unreadable path skips graft",
			config: map[string]string{"user.email": "a@b", "gpg.format": "ssh", "user.signingkey": missingPath},
			want:   "[user]\n    email = a@b\n",
			wantWarnings: []string{">> user.signingkey '" + missingPath +
				"' is not a readable file; skipping signingkey graft."},
		},
		{
			name:         "private key path rejected",
			config:       map[string]string{"gpg.format": "ssh", "user.signingkey": privateKeyFile},
			want:         "[user]\n",
			wantWarnings: []string{">> resolved user.signingkey is not a single-line ssh public key; skipping signingkey graft."},
		},
		{
			name:         "multiline key file rejected",
			config:       map[string]string{"gpg.format": "ssh", "user.signingkey": multilineFile},
			want:         "[user]\n",
			wantWarnings: []string{">> resolved user.signingkey is not a single-line ssh public key; skipping signingkey graft."},
		},
		{
			name:         "openpgp without fallback",
			config:       map[string]string{"user.email": "a@b", "user.signingkey": "ABCD1234"},
			want:         "[user]\n    email = a@b\n",
			wantWarnings: []string{">> host git uses openpgp signing; only ssh signing works in-container, and no claude-container.signingkey-ssh fallback is configured. Skipping signingkey graft (name/email still applied)."},
		},
		{
			name:         "x509 without fallback",
			config:       map[string]string{"gpg.format": "x509", "user.signingkey": "cn=whoever"},
			want:         "[user]\n",
			wantWarnings: []string{">> host git uses x509 signing; only ssh signing works in-container, and no claude-container.signingkey-ssh fallback is configured. Skipping signingkey graft (name/email still applied)."},
		},
		{
			name: "openpgp with ssh fallback",
			config: map[string]string{"user.signingkey": "ABCD1234", "claude-container.signingkey-ssh": "ssh-ed25519 AAAAFALLBACK",
				"commit.gpgsign": "true"},
			want:         "[user]\n    signingkey = ssh-ed25519 AAAAFALLBACK\n[gpg]\n    format = ssh\n[commit]\n    gpgsign = true\n",
			wantWarnings: []string{">> host git uses openpgp signing; using claude-container.signingkey-ssh fallback for in-container commit signing."},
		},
		{
			name:   "openpgp with unreadable fallback path",
			config: map[string]string{"user.email": "a@b", "user.signingkey": "ABCD1234", "claude-container.signingkey-ssh": missingPath},
			want:   "[user]\n    email = a@b\n",
			wantWarnings: []string{
				">> host git uses openpgp signing; using claude-container.signingkey-ssh fallback for in-container commit signing.",
				">> claude-container.signingkey-ssh '" + missingPath + "' is not a readable file; skipping signingkey graft.",
			},
		},
	}
	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			repository := t.TempDir()
			if output, err := exec.Command("git", "init", "-q", repository).CombinedOutput(); err != nil {
				t.Fatalf("git init: %v: %s", err, output)
			}
			for key, value := range testCase.config {
				if output, err := exec.Command("git", "-C", repository, "config", "--local", key, value).CombinedOutput(); err != nil {
					t.Fatalf("git config %s: %v: %s", key, err, output)
				}
			}
			block, warnings := GitIdentity(repository)
			if block != testCase.want {
				t.Errorf("block:\n%q\nwant:\n%q", block, testCase.want)
			}
			if !reflect.DeepEqual(warnings, testCase.wantWarnings) {
				t.Errorf("warnings %q, want %q", warnings, testCase.wantWarnings)
			}
			if strings.Contains(block, "program") {
				t.Errorf("block must never graft gpg.ssh.program: %q", block)
			}
		})
	}
}
