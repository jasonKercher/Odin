//+private
package os2

import "core:strings"
import "core:sys/unix"
import "core:path/filepath"

_Path_Separator      :: '/'
_Path_List_Separator :: ':'

_S_IFMT   :: 0o170000 // Type of file mask
_S_IFIFO  :: 0o010000 // Named pipe (fifo)
_S_IFCHR  :: 0o020000 // Character special
_S_IFDIR  :: 0o040000 // Directory
_S_IFBLK  :: 0o060000 // Block special
_S_IFREG  :: 0o100000 // Regular
_S_IFLNK  :: 0o120000 // Symbolic link
_S_IFSOCK :: 0o140000 // Socket

_OPENDIR_FLAGS :: _O_RDONLY|_O_NONBLOCK|_O_DIRECTORY|_O_LARGEFILE|_O_CLOEXEC

_is_path_separator :: proc(c: byte) -> bool {
	return c == '/'
}

_mkdir :: proc(path: string, perm: File_Mode) -> Error {
	// NOTE: These modes would require sys_mknod, however, that would require
	//       additional arguments to this function.
	if perm & (File_Mode_Named_Pipe | File_Mode_Device | File_Mode_Char_Device | File_Mode_Sym_Link) != 0 {
		return .Invalid_Argument
	}

	path_cstr, allocated := _name_to_cstring(path)
	defer if allocated {
		delete(path_cstr)
	}
	return _ok_or_error(unix.sys_mkdir(path_cstr, int(perm & 0o777)))
}

_mkdir_all :: proc(path: string, perm: File_Mode) -> Error {
	_mkdirat :: proc(dfd: Handle, path: []u8, perm: int, has_created: ^bool) -> Error {
		if len(path) == 0 {
			return _ok_or_error(unix.sys_close(int(dfd)))
		}
		i: int
		for /**/; i < len(path) - 1 && path[i] != '/'; i += 1 {}
		path[i] = 0
		new_dfd := unix.sys_openat(int(dfd), cstring(&path[0]), _OPENDIR_FLAGS)
		switch new_dfd {
		case -ENOENT:
			if res := unix.sys_mkdirat(int(dfd), cstring(&path[0]), perm); res < 0 {
				return _get_platform_error(res)
			}
			has_created^ = true
			if new_dfd = unix.sys_openat(int(dfd), cstring(&path[0]), _OPENDIR_FLAGS); new_dfd < 0 {
				return _get_platform_error(new_dfd)
			}
			fallthrough
		case 0:
			if res := unix.sys_close(int(dfd)); res < 0 {
				return _get_platform_error(res)
			}
			// skip consecutive '/'
			for i += 1; i < len(path) && path[i] == '/'; i += 1 {}
			return _mkdirat(Handle(new_dfd), path[i:], perm, has_created)
		case:
			return _get_platform_error(new_dfd)
		}
		unreachable()
	}

	if perm & (File_Mode_Named_Pipe | File_Mode_Device | File_Mode_Char_Device | File_Mode_Sym_Link) != 0 {
		return .Invalid_Argument
	}

	// need something we can edit, and use to generate cstrings
	allocated: bool
	path_bytes: []u8
	if len(path) > _CSTRING_NAME_HEAP_THRESHOLD {
		allocated = true
		path_bytes = make([]u8, len(path) + 1)
	} else {
		path_bytes = make([]u8, len(path) + 1, context.temp_allocator)
	}
	defer if allocated {
		delete(path_bytes)
	}

	// NULL terminate the byte slice to make it a valid cstring
	copy(path_bytes, path)
	path_bytes[len(path)] = 0

	dfd: int
	if path_bytes[0] == '/' {
		dfd = unix.sys_open("/", _OPENDIR_FLAGS)
		path_bytes = path_bytes[1:]
	} else {
		dfd = unix.sys_open(".", _OPENDIR_FLAGS)
	}
	if dfd < 0 {
		return _get_platform_error(dfd)
	}
	
	has_created: bool
	_mkdirat(Handle(dfd), path_bytes, int(perm & 0o777), &has_created) or_return
	if has_created {
		return nil
	}
	return .Exist
	//return has_created ? nil : .Exist
}

dirent64 :: struct {
	d_ino: u64,
	d_off: u64,
	d_reclen: u16,
	d_type: u8,
	d_name: [1]u8,
}

_remove_all :: proc(path: string) -> Error {
	DT_DIR :: 4

	_remove_all_dir :: proc(dfd: Handle) -> Error {
		n := 64
		buf := make([]u8, n)
		defer delete(buf)

		loop: for {
			res := unix.sys_getdents64(int(dfd), &buf[0], n)
			switch res {
			case -EINVAL:
				delete(buf)
				n *= 2
				buf = make([]u8, n)
				continue loop
			case -4096..<0:
				return _get_platform_error(res)
			case 0:
				break loop
			}

			d: ^dirent64

			for i := 0; i < res; i += int(d.d_reclen) {
				description: string
				d = (^dirent64)(rawptr(&buf[i]))
				d_name_cstr := cstring(&d.d_name[0])

				buf_len := uintptr(d.d_reclen) - offset_of(d.d_name)

				/* check for current directory (.) */
				#no_bounds_check if buf_len > 1 && d.d_name[0] == '.' && d.d_name[1] == 0 {
					continue
				}

				/* check for parent directory (..) */
				#no_bounds_check if buf_len > 2 && d.d_name[0] == '.' && d.d_name[1] == '.' && d.d_name[2] == 0 {
					continue
				}

				res: int

				switch d.d_type {
				case DT_DIR:
					handle_i := unix.sys_openat(int(dfd), d_name_cstr, _OPENDIR_FLAGS)
					if handle_i < 0 {
						return _get_platform_error(handle_i)
					}
					defer unix.sys_close(handle_i)
					_remove_all_dir(Handle(handle_i)) or_return
					res = unix.sys_unlinkat(int(dfd), d_name_cstr, int(unix.AT_REMOVEDIR))
				case:
					res = unix.sys_unlinkat(int(dfd), d_name_cstr) 
				}

				if res < 0 {
					return _get_platform_error(res)
				}
			}
		}
		return nil
	}

	path_cstr, allocated := _name_to_cstring(path)
	defer if allocated {
		delete(path_cstr)
	}

	handle_i := unix.sys_open(path_cstr, _OPENDIR_FLAGS)
	switch handle_i {
	case -ENOTDIR:
		return _ok_or_error(unix.sys_unlink(path_cstr))
	case -4096..<0:
		return _get_platform_error(handle_i)
	}

	fd := Handle(handle_i)
	defer close(fd)
	_remove_all_dir(fd) or_return
	return _ok_or_error(unix.sys_rmdir(path_cstr))
}

_getwd :: proc(allocator := context.allocator) -> (string, Error) {
	// NOTE(tetra): I would use PATH_MAX here, but I was not able to find
	// an authoritative value for it across all systems.
	// The largest value I could find was 4096, so might as well use the page size.
	// NOTE(jason): Avoiding libc, so just use 4096 directly
	PATH_MAX :: 4096
	buf := make([dynamic]u8, PATH_MAX, allocator)
	for {
		#no_bounds_check res := unix.sys_getcwd(&buf[0], uint(len(buf)))

		if res >= 0 {
			return strings.string_from_nul_terminated_ptr(&buf[0], len(buf)), nil
		}
		if res != -ERANGE {
			return "", _get_platform_error(res)
		}
		resize(&buf, len(buf)+PATH_MAX)
	}
	unreachable()
}

_setwd :: proc(dir: string) -> Error {
	dir_cstr, allocated := _name_to_cstring(dir)
	defer if allocated {
		delete(dir_cstr)
	}
	return _ok_or_error(unix.sys_chdir(dir_cstr))
}