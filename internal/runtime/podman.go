package runtime

import "os/exec"

type podman struct{}

func (podman) Name() string   { return "podman" }
func (podman) Binary() string { return "podman" }

func selinuxEnforcing() bool {
	if _, err := exec.LookPath("getenforce"); err != nil {
		return false
	}
	status := commandOutput("getenforce")
	return status != "" && status != "Disabled"
}

// keep-id maps the host user onto the image's claude (uid 1000), so the
// entrypoint skips its usermod/chown remap.
func (podman) RunFlags() []string {
	flags := []string{
		"--userns=keep-id:uid=1000,gid=1000",
		// keep-id also defaults the container user to 1000; without root here the
		// entrypoint's first `gosu claude` fails (setgroups needs CAP_SETGID).
		// Root is a subuid on the host, and the entrypoint still drops to claude.
		"--user", "0:0",
		"-e", "_CLAUDE_UID_REMAP=skip",
	}
	if selinuxEnforcing() {
		// Preferred over per-mount :z, which would relabel shared dirs like ~/.claude.
		flags = append(flags, "--security-opt", "label=disable")
	}
	return flags
}

func (podman) SSHFlags(socket string) []string { return socketMountFlags(socket) }

func (podman) Pull(image string) error { return pull("podman", "pull", image) }

func (podman) ImageLabel(image, key string) string { return inspectLabel("podman", image, key) }
