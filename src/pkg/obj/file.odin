package obj

import "core:os"

// The only file in this package that touches core:os, so a stdlib API change stays a
// two-line fix. Written for the redesigned core:os (the former core:os/os2, which became
// core:os in 2026), where read_entire_file / write_entire_file return an `os.Error` that
// is nil on success. On an older compiler whose core:os still returns `bool`, adapt these
// two procedures.

read_file :: proc(path: string, allocator := context.allocator) -> (data: []byte, ok: bool) {
	bytes, err := os.read_entire_file(path, allocator)
	if err != nil {
		return nil, false
	}
	return bytes, true
}

write_file :: proc(path: string, data: []byte) -> bool {
	return os.write_entire_file(path, data) == nil
}
