package app

import (
	"os"
	"syscall"
	"unsafe"
)

// isTerminal asks the tty driver, like `[[ -t ]]`. A ModeCharDevice check
// would also accept /dev/null, and `-it` with stdin from /dev/null fails.
func isTerminal(file *os.File) bool {
	var termios syscall.Termios
	_, _, errorNumber := syscall.Syscall(syscall.SYS_IOCTL, file.Fd(), terminalAttributesRequest, uintptr(unsafe.Pointer(&termios)))
	return errorNumber == 0
}
