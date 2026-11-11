package launch

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"syscall"

	"github.com/multigl/claude-container/internal/config"
	"github.com/multigl/claude-container/internal/flavor"
	"github.com/multigl/claude-container/internal/paths"
	"github.com/multigl/claude-container/internal/runtime"
)

type RunOptions struct {
	Paths   paths.Paths
	Config  config.Config
	Runtime runtime.Runtime
	Flavor  flavor.Flavor
	Stage   Stage
	Image   string
	Getenv  func(string) string
	Host    runtime.Host
	UID     int
	GID     int
	// TTY is true only when both stdin and stdout are terminals.
	TTY     bool
	Reseed  bool
	Command []string
	// Home expands a leading ~ in configured mounts.
	Home string
	// WorkingDirectory is the host dir mounted at /workspace.
	WorkingDirectory string
}

func sshFlags(o RunOptions) (flags []string, warnings []string) {
	if !SSHEnabled(o.Getenv, o.Config) {
		return nil, nil
	}
	if !SSHSupported(o.Runtime.Name(), o.Host) {
		return nil, []string{fmt.Sprintf(">> SSH forwarding unsupported on %s for this host; use apple `container` or push over HTTPS. Skipping.", o.Runtime.Name())}
	}
	flags = o.Runtime.SSHFlags(o.Getenv("SSH_AUTH_SOCK"))
	if len(flags) == 0 {
		return nil, []string{">> SSH forwarding enabled but SSH_AUTH_SOCK is unset (no agent running?); skipping."}
	}
	return flags, nil
}

// BuildArgs assembles the full container argv in the bash launcher's order,
// which testdata/parity pins.
func BuildArgs(o RunOptions) (args []string, warnings []string) {
	args = []string{o.Runtime.Binary(), "run", "--rm"}
	if o.TTY {
		args = append(args, "-it")
	}
	args = append(args, "-v", o.Stage.Dir+":/opt/claude-stage:ro")
	args = append(args, o.Flavor.RunFlags()...)
	if o.Reseed {
		args = append(args, "-e", "CLAUDE_RESEED=1")
	}
	mountFlags, mountWarnings := MountFlags(o.Config.Mounts, o.Home)
	args = append(args, mountFlags...)
	warnings = append(warnings, mountWarnings...)
	args = append(args, o.Runtime.RunFlags()...)
	forwardingFlags, sshWarnings := sshFlags(o)
	args = append(args, forwardingFlags...)
	warnings = append(warnings, sshWarnings...)
	dnsFlags, dnsWarnings := DNSFlags(DNSServers(o.Getenv, o.Config))
	args = append(args, dnsFlags...)
	warnings = append(warnings, dnsWarnings...)
	args = append(args,
		"--env-file", o.Stage.EnvFile,
		"-e", fmt.Sprintf("HOST_UID=%d", o.UID),
		"-e", fmt.Sprintf("HOST_GID=%d", o.GID),
		"-e", "CLAUDE_HOST_DIR="+o.WorkingDirectory,
		"-v", o.WorkingDirectory+":/workspace",
		"-v", o.Paths.StateClaudeDir+":/home/claude/.claude",
		"-v", o.Paths.HostProjectDir+":/home/claude/.claude/projects/-workspace",
		"-w", "/workspace",
		o.Image,
	)
	args = append(args, o.Command...)
	return args, warnings
}

// Run executes args with inherited stdio and returns the child's exit code.
// It never execs in place, so the caller's deferred stage cleanup still runs.
func Run(args []string) int {
	command := exec.Command(args[0], args[1:]...)
	command.Stdin = os.Stdin
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr

	// Registered before Start so a signal arriving during startup is relayed
	// instead of killing the launcher and orphaning the stage dir.
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(signals)

	if err := command.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "!! %v\n", err)
		return 127
	}
	done := make(chan struct{})
	go func() {
		for {
			select {
			case received := <-signals:
				command.Process.Signal(received)
			case <-done:
				return
			}
		}
	}()
	err := command.Wait()
	close(done)

	var exitError *exec.ExitError
	if err != nil && !errors.As(err, &exitError) {
		fmt.Fprintf(os.Stderr, "!! %v\n", err)
		return 1
	}
	// Match the shell convention for a signal-killed child; ExitCode() gives -1.
	if status, ok := command.ProcessState.Sys().(syscall.WaitStatus); ok && status.Signaled() {
		return 128 + int(status.Signal())
	}
	return command.ProcessState.ExitCode()
}
