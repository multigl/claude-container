// Package runtime detects and drives the container runtimes (apple, docker,
// podman) the launcher can run the image under.
package runtime

import (
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

type Runtime interface {
	Name() string
	Binary() string
	RunFlags() []string
	SSHFlags(socket string) []string
	Pull(image string) error
	ImageLabel(image, key string) string
}

// Host is read from uname/sw_vers rather than Go's GOOS so tests can fake it.
type Host struct {
	OS         string
	Arch       string
	MacOSMajor int
}

func commandOutput(name string, arguments ...string) string {
	output, err := exec.Command(name, arguments...).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(output))
}

func ProbeHost() Host {
	major, _, _ := strings.Cut(commandOutput("sw_vers", "-productVersion"), ".")
	macOSMajor, _ := strconv.Atoi(major)
	return Host{
		OS:         commandOutput("uname", "-s"),
		Arch:       commandOutput("uname", "-m"),
		MacOSMajor: macOSMajor,
	}
}

// functional reports whether the binary is installed and its health probe succeeds.
func functional(binary string, probe ...string) bool {
	if _, err := exec.LookPath(binary); err != nil {
		return false
	}
	return exec.Command(binary, probe...).Run() == nil
}

func Available(name string, host Host) bool {
	switch name {
	case "docker":
		return functional("docker", "info")
	case "podman":
		return functional("podman", "info")
	case "apple":
		// apple `container` needs Apple Silicon and macOS 26+.
		eligible := host.OS == "Darwin" && host.Arch == "arm64" && host.MacOSMajor >= 26
		return eligible && functional("container", "system", "status")
	}
	return false
}

// Resolve returns the override if set and available, else the first available
// runtime in priority order, or "none".
func Resolve(override string, host Host) string {
	if override != "" {
		if Available(override, host) {
			return override
		}
		return "none"
	}
	for _, name := range []string{"apple", "docker", "podman"} {
		if Available(name, host) {
			return name
		}
	}
	return "none"
}

func New(name string) (Runtime, error) {
	switch name {
	case "docker":
		return docker{}, nil
	case "podman":
		return podman{}, nil
	case "apple":
		return apple{}, nil
	}
	return nil, fmt.Errorf("unknown container runtime %q", name)
}

func pull(binary string, arguments ...string) error {
	command := exec.Command(binary, arguments...)
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	return command.Run()
}

// socketMountFlags binds the host agent socket in and points SSH_AUTH_SOCK at it.
func socketMountFlags(socket string) []string {
	if socket == "" {
		return nil
	}
	return []string{"-v", socket + ":/ssh-agent", "-e", "SSH_AUTH_SOCK=/ssh-agent"}
}

func inspectLabel(binary, image, key string) string {
	return commandOutput(binary, "image", "inspect", "-f", fmt.Sprintf(`{{ index .Config.Labels %q }}`, key), image)
}
