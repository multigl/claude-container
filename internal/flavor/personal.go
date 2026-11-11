package flavor

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/multigl/claude-container/internal/config"
	"github.com/multigl/claude-container/internal/paths"
)

// No cred bind dir: Claude Code writes ~/.claude/.credentials.json, already
// inside the state mount. It opens that file O_NOFOLLOW, so never symlink it.
// The token is plaintext (no keychain in the container); the 0700 state dir
// and the file's own 0600 are the whole mitigation.
type personal struct {
	paths          paths.Paths
	credentialFile string
}

func newPersonal(p paths.Paths) personal {
	return personal{paths: p, credentialFile: filepath.Join(p.StateClaudeDir, ".credentials.json")}
}

func (f personal) Name() string        { return "personal" }
func (f personal) CredDirs() []string  { return nil }
func (f personal) CredPaths() []string { return []string{f.credentialFile} }
func (f personal) RunFlags() []string  { return nil }

func (f personal) AuthCommand() ([]string, string, string) {
	return []string{"claude", "auth", "login", "--claudeai"},
		">> signing in to your Anthropic account inside the container",
		">> done. credential saved to " + f.credentialFile
}

func (f personal) SeedConfig() string {
	return seedConfig("personal", `# claude-personal: signs in to your Anthropic account with `+"`claude-personal auth`"+`
# (OAuth, completed in your host browser). No API key, no gateway, no Vertex.
# Nothing model-related is pinned here -- pick models with /model in the session.

`, context7Block())
}

func (f personal) PrintPaths() []string {
	return []string{"CRED_PERSONAL_FILE=" + f.credentialFile}
}

func (f personal) Doctor(config.Config) []string {
	var lines []string
	credentialInfo, credentialErr := os.Stat(f.credentialFile)
	if credentialErr == nil {
		lines = append(lines, fmt.Sprintf("  ok: Anthropic credential present (%s)", f.credentialFile))
	} else {
		lines = append(lines, "  MISSING: run 'claude-personal auth'")
	}
	// The mitigation for a plaintext token is the permissions, so check them
	// rather than assume the chmod ran.
	if directoryInfo, err := os.Stat(f.paths.StateClaudeDir); err == nil && directoryInfo.Mode().Perm() != 0o700 {
		lines = append(lines, fmt.Sprintf("  WARN: %s is %s, expected drwx------", f.paths.StateClaudeDir, directoryInfo.Mode()))
	}
	if credentialErr == nil && credentialInfo.Mode().Perm() != 0o600 {
		lines = append(lines, fmt.Sprintf("  WARN: %s is %s, expected -rw-------", f.credentialFile, credentialInfo.Mode()))
	}
	return lines
}

func (f personal) LegacyVolume() string { return "" }
