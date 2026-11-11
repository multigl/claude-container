package launch

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/multigl/claude-container/internal/config"
	"github.com/multigl/claude-container/internal/runtime"
)

func getenvFrom(values map[string]string) func(string) string {
	return func(key string) string { return values[key] }
}

func TestDNSServers(t *testing.T) {
	testCases := []struct {
		name        string
		environment map[string]string
		cfg         config.Config
		want        []string
	}{
		{"environment wins and splits commas and spaces", map[string]string{"CLAUDE_DNS": "1.1.1.1, ::1"}, config.Config{DNS: []string{"9.9.9.9"}}, []string{"1.1.1.1", "::1"}},
		{"config used when environment empty", nil, config.Config{DNS: []string{"9.9.9.9"}}, []string{"9.9.9.9"}},
		{"none", nil, config.Config{}, nil},
	}
	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			got := DNSServers(getenvFrom(testCase.environment), testCase.cfg)
			if !reflect.DeepEqual(got, testCase.want) {
				t.Fatalf("got %v, want %v", got, testCase.want)
			}
		})
	}
}

func TestDNSFlags(t *testing.T) {
	testCases := []struct {
		name         string
		servers      []string
		wantFlags    []string
		wantWarnings []string
	}{
		{"ipv4 and ipv6", []string{"1.1.1.1", "::1"}, []string{"--dns", "1.1.1.1", "--dns", "::1"}, nil},
		{"flag smuggling dropped", []string{"--privileged"}, nil, []string{">> dns: '--privileged' is not an IP address; ignored"}},
		{"none", nil, nil, nil},
	}
	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			flags, warnings := DNSFlags(testCase.servers)
			if !reflect.DeepEqual(flags, testCase.wantFlags) || !reflect.DeepEqual(warnings, testCase.wantWarnings) {
				t.Fatalf("got %v %v, want %v %v", flags, warnings, testCase.wantFlags, testCase.wantWarnings)
			}
		})
	}
}

func TestMountFlags(t *testing.T) {
	home := t.TempDir()
	notes := filepath.Join(home, "notes")
	scratch := filepath.Join(home, "scratch")
	otherNotes := filepath.Join(t.TempDir(), "notes")
	for _, directory := range []string{notes, scratch, otherNotes} {
		if err := os.MkdirAll(directory, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	missing := filepath.Join(home, "missing")

	testCases := []struct {
		name         string
		mounts       []config.Mount
		wantFlags    []string
		wantWarnings []string
	}{
		{"tilde expanded, read-only default", []config.Mount{{Path: "~/notes"}}, []string{"-v", notes + ":/mnt/approved/notes:ro"}, nil},
		{"rw suffix", []config.Mount{{Path: "~/scratch", RW: true}}, []string{"-v", scratch + ":/mnt/approved/scratch:rw"}, nil},
		{"missing directory", []config.Mount{{Path: "~/missing"}}, nil, []string{">> skip mount: not a directory: " + missing}},
		{"duplicate basename", []config.Mount{{Path: notes}, {Path: otherNotes}},
			[]string{"-v", notes + ":/mnt/approved/notes:ro"},
			[]string{">> skip mount: duplicate basename 'notes' (" + otherNotes + ")"}},
	}
	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			flags, warnings := MountFlags(testCase.mounts, home)
			if !reflect.DeepEqual(flags, testCase.wantFlags) || !reflect.DeepEqual(warnings, testCase.wantWarnings) {
				t.Fatalf("got %v %v, want %v %v", flags, warnings, testCase.wantFlags, testCase.wantWarnings)
			}
		})
	}
}

func TestSSHEnabled(t *testing.T) {
	testCases := []struct {
		name        string
		environment map[string]string
		cfg         config.Config
		want        bool
	}{
		{"default off", nil, config.Config{}, false},
		{"config on", nil, config.Config{ForwardSSH: true}, true},
		{"environment on", map[string]string{"CLAUDE_FORWARD_SSH": "1"}, config.Config{}, true},
		{"environment yes uppercase", map[string]string{"CLAUDE_FORWARD_SSH": "YES"}, config.Config{}, true},
		{"environment true", map[string]string{"CLAUDE_FORWARD_SSH": "True"}, config.Config{}, true},
		{"environment overrides config off", map[string]string{"CLAUDE_FORWARD_SSH": "0"}, config.Config{ForwardSSH: true}, false},
		{"environment garbage is off", map[string]string{"CLAUDE_FORWARD_SSH": "maybe"}, config.Config{ForwardSSH: true}, false},
	}
	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			if got := SSHEnabled(getenvFrom(testCase.environment), testCase.cfg); got != testCase.want {
				t.Fatalf("got %v, want %v", got, testCase.want)
			}
		})
	}
}

func TestSSHSupported(t *testing.T) {
	darwin := runtime.Host{OS: "Darwin", Arch: "arm64", MacOSMajor: 26}
	linux := runtime.Host{OS: "Linux", Arch: "x86_64"}
	testCases := []struct {
		name    string
		runtime string
		host    runtime.Host
		want    bool
	}{
		{"apple on darwin", "apple", darwin, true},
		{"docker on darwin", "docker", darwin, false},
		{"podman on darwin", "podman", darwin, false},
		{"docker on linux", "docker", linux, true},
		{"podman on linux", "podman", linux, true},
	}
	for _, testCase := range testCases {
		t.Run(testCase.name, func(t *testing.T) {
			if got := SSHSupported(testCase.runtime, testCase.host); got != testCase.want {
				t.Fatalf("got %v, want %v", got, testCase.want)
			}
		})
	}
}
