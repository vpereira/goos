//go:build tools

package tools

import (
	_ "github.com/kr/fs"
	_ "github.com/pkg/sftp"
	_ "golang.org/x/crypto/ssh"
)
