package runtime

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// installFakes puts the named fake executables on an otherwise empty PATH.
// Each fake runs the given shell body; only shell builtins are available.
func installFakes(t *testing.T, fakes map[string]string) string {
	t.Helper()
	binDirectory := t.TempDir()
	for name, body := range fakes {
		script := "#!/bin/sh\n" + body + "\n"
		if err := os.WriteFile(filepath.Join(binDirectory, name), []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", binDirectory)
	return binDirectory
}

func TestProbeHost(t *testing.T) {
	tests := []struct {
		name  string
		fakes map[string]string
		want  Host
	}{
		{
			name: "macOS Apple Silicon",
			fakes: map[string]string{
				"uname":   `if [ "$1" = "-s" ]; then echo Darwin; else echo arm64; fi`,
				"sw_vers": `echo 26.1`,
			},
			want: Host{OS: "Darwin", Arch: "arm64", MacOSMajor: 26},
		},
		{
			name: "Linux without sw_vers",
			fakes: map[string]string{
				"uname": `if [ "$1" = "-s" ]; then echo Linux; else echo x86_64; fi`,
			},
			want: Host{OS: "Linux", Arch: "x86_64", MacOSMajor: 0},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			installFakes(t, test.fakes)
			if got := ProbeHost(); got != test.want {
				t.Errorf("ProbeHost() = %+v, want %+v", got, test.want)
			}
		})
	}
}

func TestResolve(t *testing.T) {
	working := `exit 0`
	tests := []struct {
		name     string
		fakes    map[string]string
		override string
		host     Host
		want     string
	}{
		{"Linux with docker and podman prefers docker", map[string]string{"docker": working, "podman": working}, "", Host{OS: "Linux", Arch: "x86_64"}, "docker"},
		{"Linux with only podman", map[string]string{"podman": working}, "", Host{OS: "Linux", Arch: "x86_64"}, "podman"},
		{"Darwin arm64 26 with apple container", map[string]string{"container": working, "docker": working}, "", Host{OS: "Darwin", Arch: "arm64", MacOSMajor: 26}, "apple"},
		{"Darwin 15 falls back to docker", map[string]string{"container": working, "docker": working}, "", Host{OS: "Darwin", Arch: "arm64", MacOSMajor: 15}, "docker"},
		{"Darwin x86_64 26 is not apple eligible", map[string]string{"container": working, "docker": working}, "", Host{OS: "Darwin", Arch: "x86_64", MacOSMajor: 26}, "docker"},
		{"Linux ignores a container binary", map[string]string{"container": working, "docker": working}, "", Host{OS: "Linux", Arch: "x86_64"}, "docker"},
		{"non-functional docker is skipped", map[string]string{"docker": `exit 1`, "podman": working}, "", Host{OS: "Linux", Arch: "x86_64"}, "podman"},
		{"override picks available runtime", map[string]string{"docker": working, "podman": working}, "podman", Host{OS: "Linux", Arch: "x86_64"}, "podman"},
		{"override of unavailable runtime gives none", map[string]string{"docker": working}, "podman", Host{OS: "Linux", Arch: "x86_64"}, "none"},
		{"unknown override gives none", map[string]string{"docker": working}, "lxc", Host{OS: "Linux", Arch: "x86_64"}, "none"},
		{"nothing available", map[string]string{}, "", Host{OS: "Linux", Arch: "x86_64"}, "none"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			installFakes(t, test.fakes)
			if got := Resolve(test.override, test.host); got != test.want {
				t.Errorf("Resolve(%q, %+v) = %q, want %q", test.override, test.host, got, test.want)
			}
		})
	}
}

func TestRunFlags(t *testing.T) {
	podmanBase := []string{"--userns=keep-id:uid=1000,gid=1000", "--user", "0:0", "-e", "_CLAUDE_UID_REMAP=skip"}
	tests := []struct {
		name    string
		runtime string
		fakes   map[string]string
		want    []string
	}{
		{"docker", "docker", nil, nil},
		{"apple", "apple", nil, nil},
		{"podman without getenforce", "podman", nil, podmanBase},
		{"podman with SELinux enforcing", "podman", map[string]string{"getenforce": `echo Enforcing`}, append(append([]string{}, podmanBase...), "--security-opt", "label=disable")},
		{"podman with SELinux disabled", "podman", map[string]string{"getenforce": `echo Disabled`}, podmanBase},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			installFakes(t, test.fakes)
			runtime, err := New(test.runtime)
			if err != nil {
				t.Fatal(err)
			}
			if got := runtime.RunFlags(); !reflect.DeepEqual(got, test.want) {
				t.Errorf("RunFlags() = %v, want %v", got, test.want)
			}
		})
	}
}

func TestSSHFlags(t *testing.T) {
	mounted := []string{"-v", "/s.sock:/ssh-agent", "-e", "SSH_AUTH_SOCK=/ssh-agent"}
	tests := []struct {
		runtime string
		socket  string
		want    []string
	}{
		{"docker", "/s.sock", mounted},
		{"podman", "/s.sock", mounted},
		{"apple", "/s.sock", []string{"--ssh"}},
		{"docker", "", nil},
		{"podman", "", nil},
		{"apple", "", nil},
	}
	for _, test := range tests {
		t.Run(test.runtime+" socket="+test.socket, func(t *testing.T) {
			runtime, err := New(test.runtime)
			if err != nil {
				t.Fatal(err)
			}
			if got := runtime.SSHFlags(test.socket); !reflect.DeepEqual(got, test.want) {
				t.Errorf("SSHFlags(%q) = %v, want %v", test.socket, got, test.want)
			}
		})
	}
}

func TestPull(t *testing.T) {
	tests := []struct {
		runtime string
		binary  string
		want    string
	}{
		{"docker", "docker", "pull IMG"},
		{"podman", "podman", "pull IMG"},
		{"apple", "container", "image pull IMG"},
	}
	for _, test := range tests {
		t.Run(test.runtime, func(t *testing.T) {
			recordFile := filepath.Join(t.TempDir(), "argv")
			installFakes(t, map[string]string{test.binary: `echo "$@" >> ` + recordFile})
			runtime, err := New(test.runtime)
			if err != nil {
				t.Fatal(err)
			}
			if err := runtime.Pull("IMG"); err != nil {
				t.Fatal(err)
			}
			recorded, err := os.ReadFile(recordFile)
			if err != nil {
				t.Fatal(err)
			}
			if got := strings.TrimSpace(string(recorded)); got != test.want {
				t.Errorf("argv = %q, want %q", got, test.want)
			}
		})
	}
}

func TestPullReturnsRuntimeError(t *testing.T) {
	installFakes(t, map[string]string{"docker": `exit 3`})
	runtime, _ := New("docker")
	if err := runtime.Pull("IMG"); err == nil {
		t.Error("Pull() = nil, want error from failing runtime")
	}
}

func TestImageLabel(t *testing.T) {
	tests := []struct {
		runtime string
		binary  string
		want    string
	}{
		{"docker", "docker", "1.2.3"},
		{"podman", "podman", "1.2.3"},
		{"apple", "container", ""},
	}
	for _, test := range tests {
		t.Run(test.runtime, func(t *testing.T) {
			installFakes(t, map[string]string{test.binary: `echo 1.2.3`})
			runtime, _ := New(test.runtime)
			if got := runtime.ImageLabel("IMG", "org.opencontainers.image.version"); got != test.want {
				t.Errorf("ImageLabel() = %q, want %q", got, test.want)
			}
		})
	}
}

func TestNewUnknownRuntime(t *testing.T) {
	if _, err := New("lxc"); err == nil {
		t.Error("New(\"lxc\") = nil error, want error")
	}
}
