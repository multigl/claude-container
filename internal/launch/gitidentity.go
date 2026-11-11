package launch

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
)

var sshPublicKeyPrefixes = []string{"ssh-", "ecdsa-", "sk-", "key::"}

func hasSSHPublicKeyPrefix(value string) bool {
	for _, prefix := range sshPublicKeyPrefixes {
		if strings.HasPrefix(value, prefix) {
			return true
		}
	}
	return false
}

// gitConfigValue returns "" for unset keys and any git failure, like the bash.
func gitConfigValue(workingDirectory string, arguments ...string) string {
	command := exec.Command("git", append([]string{"-C", workingDirectory, "config", "--get"}, arguments...)...)
	output, err := command.Output()
	if err != nil {
		return ""
	}
	return strings.TrimRight(string(output), "\n")
}

// resolveSSHPublicKeyLiteral turns a literal ssh public key or a path to one
// into a single-line literal. The literal-prefix check runs before the path
// heuristic because key bodies are base64 and contain '/'. label only names
// the setting in the warning.
func resolveSSHPublicKeyLiteral(key, label, home string) (string, string) {
	literal := key
	if !hasSSHPublicKeyPrefix(key) && (strings.HasPrefix(key, "/") || strings.HasPrefix(key, "~") ||
		strings.HasPrefix(key, "./") || strings.Contains(key, "/")) {
		path := key
		if strings.HasPrefix(path, "~") {
			path = home + path[1:]
		}
		content, err := os.ReadFile(path)
		if err != nil {
			return "", fmt.Sprintf(">> %s '%s' is not a readable file; skipping signingkey graft.", label, key)
		}
		literal = strings.TrimRight(string(content), "\n")
	}
	// Guards multiline files, private-key paths and garbage, which would emit
	// an invalid ~/.gitconfig or copy a secret into the stage dir.
	if literal == "" || strings.Contains(literal, "\n") || !hasSSHPublicKeyPrefix(literal) {
		return "", fmt.Sprintf(">> resolved %s is not a single-line ssh public key; skipping signingkey graft.", label)
	}
	return literal, ""
}

// GitIdentity renders the [user]/[gpg]/[commit] block for the container's
// gitconfig, resolved fresh from workingDirectory so includeIf picks the right
// identity. Only ssh signing works in-container; a gpg/x509 host falls back to
// claude-container.signingkey-ssh when configured.
func GitIdentity(workingDirectory string) (block string, warnings []string) {
	home, _ := os.UserHomeDir()
	name := gitConfigValue(workingDirectory, "user.name")
	email := gitConfigValue(workingDirectory, "user.email")
	format := gitConfigValue(workingDirectory, "gpg.format")
	key := gitConfigValue(workingDirectory, "user.signingkey")
	sign := gitConfigValue(workingDirectory, "--type=bool", "commit.gpgsign")

	var builder strings.Builder
	builder.WriteString("[user]\n")
	if name != "" {
		fmt.Fprintf(&builder, "    name = %s\n", name)
	}
	if email != "" {
		fmt.Fprintf(&builder, "    email = %s\n", email)
	}
	if key == "" {
		return builder.String(), nil
	}

	var literal, warning string
	if format == "ssh" {
		literal, warning = resolveSSHPublicKeyLiteral(key, "user.signingkey", home)
	} else {
		shownFormat := format
		if shownFormat == "" {
			shownFormat = "openpgp"
		}
		fallback := gitConfigValue(workingDirectory, "claude-container.signingkey-ssh")
		if fallback == "" {
			warnings = append(warnings, fmt.Sprintf(">> host git uses %s signing; only ssh signing works in-container, and no claude-container.signingkey-ssh fallback is configured. Skipping signingkey graft (name/email still applied).", shownFormat))
			return builder.String(), warnings
		}
		warnings = append(warnings, fmt.Sprintf(">> host git uses %s signing; using claude-container.signingkey-ssh fallback for in-container commit signing.", shownFormat))
		literal, warning = resolveSSHPublicKeyLiteral(fallback, "claude-container.signingkey-ssh", home)
	}
	if warning != "" {
		return builder.String(), append(warnings, warning)
	}

	// Never graft gpg.ssh.program: the host's op-ssh-sign path doesn't exist in
	// the container; git then uses its own ssh-keygen via the forwarded agent.
	gpgSign := "false"
	if sign == "true" {
		gpgSign = "true"
	}
	fmt.Fprintf(&builder, "    signingkey = %s\n", literal)
	builder.WriteString("[gpg]\n    format = ssh\n")
	fmt.Fprintf(&builder, "[commit]\n    gpgsign = %s\n", gpgSign)
	return builder.String(), warnings
}
