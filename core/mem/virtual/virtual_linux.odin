//+build linux
//+private
package mem_virtual

import "base:runtime"

import "core:mem"
import "core:strconv"
import "core:sys/linux"

_reserve :: proc "contextless" (size: uint) -> (data: []byte, err: Allocator_Error) {
	addr, errno := linux.mmap(0, size, {}, {.PRIVATE, .ANONYMOUS})
	if errno == .ENOMEM {
		return nil, .Out_Of_Memory
	} else if errno == .EINVAL {
		return nil, .Invalid_Argument
	}
	return (cast([^]byte)addr)[:size], nil
}

_commit :: proc "contextless" (data: rawptr, size: uint) -> Allocator_Error {
	errno := linux.mprotect(data, size, {.READ, .WRITE})
	if errno == .EINVAL {
		return .Invalid_Pointer
	} else if errno == .ENOMEM {
		return .Out_Of_Memory
	}
	return nil
}

_decommit :: proc "contextless" (data: rawptr, size: uint) {
	_ = linux.mprotect(data, size, {})
	_ = linux.madvise(data, size, .FREE)
}

_release :: proc "contextless" (data: rawptr, size: uint) {
	_ = linux.munmap(data, size)
}

_protect :: proc "contextless" (data: rawptr, size: uint, flags: Protect_Flags) -> bool {
	pflags: linux.Mem_Protection
	pflags = {}
	if .Read    in flags { pflags |= {.READ}  }
	if .Write   in flags { pflags |= {.WRITE} }
	if .Execute in flags { pflags |= {.EXEC}  }
	errno := linux.mprotect(data, size, pflags)
	return errno == .NONE
}

_platform_memory_init :: proc() {
	DEFAULT_PAGE_SIZE = 4096
	// is power of two
	assert(DEFAULT_PAGE_SIZE != 0 && (DEFAULT_PAGE_SIZE & (DEFAULT_PAGE_SIZE-1)) == 0)
}


_map_file :: proc "contextless" (fd: uintptr, size: i64, flags: Map_File_Flags) -> (data: []byte, error: Map_File_Error) {
	prot: linux.Mem_Protection
	if .Read in flags {
		prot += {.READ}
	}
	if .Write in flags {
		prot += {.WRITE}
	}

	flags := linux.Map_Flags{.SHARED}
	addr, errno := linux.mmap(0, uint(size), prot, flags, linux.Fd(fd), offset=0)
	if addr == nil || errno != nil {
		return nil, .Map_Failure
	}
	return ([^]byte)(addr)[:size], nil
}

Huge_Page :: struct {
	addr: rawptr,
	page_size_in_4k: u32,
	page_count: u32,
}

Page_Allocator_Platform_Data :: struct {
	huge_pages: [dynamic]Huge_Page,
}

MMAP_FLAGS   : linux.Map_Flags      : {.ANONYMOUS, .PRIVATE}
MMAP_PROT    : linux.Mem_Protection : {.READ, .WRITE}

HUGE_PAGE_SIZE_DEFAULT :: 2 * mem.Megabyte

_set_system_large_page_count :: proc(count: int) -> (okay: bool) {
	// Expect this to fail because of permissions. Sudo can't even do this.
	fd, errno := linux.open("/proc/sys/vm/nr_hugepages", {.WRONLY, .TRUNC})
	if errno != nil {
		return false
	}
	defer linux.close(fd)

	buf: [24]u8
	s := strconv.append_int(buf[:], i64(count), 10)

	_, errno = linux.write(fd, buf[:len(s)])
	return errno == nil
}

_page_allocator_init :: proc(allocator: ^Page_Allocator, flags: Page_Allocator_Flags) {
	raw_array := (^runtime.Raw_Dynamic_Array)(&allocator.platform.huge_pages)
	raw_array.allocator.procedure = page_allocator_proc
}

_page_aligned_alloc :: proc(size, align, offset_pages: int,
			    flags: Page_Allocator_Flags, data: ^Page_Allocator_Platform_Data) -> ([]byte, Allocator_Error) {
	aligned_size  := mem.align_forward_int(size, mem.DEFAULT_PAGE_SIZE)
	aligned_align := mem.align_forward_int(align, mem.DEFAULT_PAGE_SIZE)

	offset := offset_pages * mem.DEFAULT_PAGE_SIZE

	// 1 GB *huge* page
	if .Allow_Large_Pages in flags && offset == 0 && size >= 1 * mem.Gigabyte {
		raw_map_flags : i32 = transmute(i32)(MMAP_FLAGS) | i32(linux.MAP_HUGE_1GB)
		map_flags := transmute(linux.Map_Flags)(raw_map_flags)
		map_flags += {.HUGETLB}

		aligned_1gb_size := mem.align_forward_int(aligned_size, 1 * mem.Gigabyte)
		if ptr, errno := linux.mmap(0, uint(aligned_1gb_size), MMAP_PROT, map_flags); ptr != nil && errno == nil {
			if data != nil {
				huge_page := Huge_Page {
					addr = ptr,
					page_size_in_4k = u32((1 * mem.Gigabyte) / (4 * mem.Kilobyte)),
					page_count = u32(aligned_1gb_size / (1 * mem.Gigabyte)),
				}
				append(&data.huge_pages, huge_page)
			}
			return mem.byte_slice(ptr, size), nil
		}
	}

	// 2 MB huge page
	attempt_2MB: if .Allow_Large_Pages in flags && offset == 0 && size >= HUGE_PAGE_SIZE_DEFAULT {
		raw_map_flags : i32 = transmute(i32)(MMAP_FLAGS) | i32(linux.MAP_HUGE_2MB)
		map_flags := transmute(linux.Map_Flags)(raw_map_flags)
		map_flags += {.HUGETLB}

		aligned_2mb_size  := mem.align_forward_int(aligned_size, HUGE_PAGE_SIZE_DEFAULT)
		aligned_2mb_align := mem.align_forward_int(aligned_align, HUGE_PAGE_SIZE_DEFAULT)

		mapping_size := aligned_2mb_size
		if aligned_align > HUGE_PAGE_SIZE_DEFAULT {
			mapping_size += aligned_2mb_align - HUGE_PAGE_SIZE_DEFAULT
		}

		ptr, errno := linux.mmap(0, uint(mapping_size), MMAP_PROT, map_flags)
		if ptr == nil || errno != nil {
			break attempt_2MB
		}

		huge_page := Huge_Page {
			addr = ptr,
			page_size_in_4k = u32(HUGE_PAGE_SIZE_DEFAULT / (4 * mem.Kilobyte)),
			page_count = u32(aligned_2mb_size / HUGE_PAGE_SIZE_DEFAULT),
		}
		defer if data != nil {
			append(&data.huge_pages, huge_page)
		}

		if mapping_size == aligned_2mb_size {
			return mem.byte_slice(ptr, size), nil
		}

		aligned_addr := mem.align_forward_int(int(uintptr(ptr)), aligned_2mb_align)
		base_waste := aligned_addr - int(uintptr(ptr))
		end_waste  := (aligned_2mb_align - HUGE_PAGE_SIZE_DEFAULT) - base_waste
		if base_waste > 0 {
			linux.munmap(ptr, uint(base_waste))
		}
		if end_waste > 0 {
			linux.munmap(rawptr(uintptr(aligned_addr + aligned_2mb_size)), uint(end_waste))
		}

		huge_page.addr = rawptr(uintptr(aligned_addr))
		return mem.byte_slice(rawptr(uintptr(aligned_addr)), size), nil
	}

	mapping_size := aligned_size
	if align > mem.DEFAULT_PAGE_SIZE {
		// Add extra pages
		mapping_size += aligned_align - mem.DEFAULT_PAGE_SIZE
	}
	mapping_size -= offset

	ptr, errno := linux.mmap(0, uint(mapping_size), MMAP_PROT, MMAP_FLAGS)
	if errno != nil || ptr == nil {
		return nil, .Out_Of_Memory
	}

	// If these don't match, we added extra for alignment.
	// Find the correct alignment, and unmap the waste.
	if aligned_size != mapping_size {
		aligned_addr := mem.align_forward_int(int(uintptr(ptr)), aligned_align)
		base_addr    := aligned_addr + offset

		base_waste := base_addr - int(uintptr(ptr))
		end_waste  := (aligned_align - mem.DEFAULT_PAGE_SIZE) - base_waste
		if base_waste > 0 {
			linux.munmap(ptr, uint(base_waste))
		}
		if end_waste > 0 {
			linux.munmap(rawptr(uintptr(aligned_addr) + uintptr(aligned_size)), uint(end_waste))
		}
		ptr = rawptr(uintptr(base_addr))
	}
	return mem.byte_slice(ptr, size), nil
}

_page_aligned_resize :: proc(old_ptr: rawptr,
			     old_size, new_size, new_align, offset_pages: int,
			     flags: Page_Allocator_Flags, data: ^Page_Allocator_Platform_Data) -> (new_memory: []byte, err: Allocator_Error) {
	if old_ptr == nil || !page_aligned(old_ptr) {
		return nil, .Invalid_Pointer
	}

	old_align := mem.DEFAULT_PAGE_SIZE
	hp_idx    := _get_huge_page_idx(data, old_ptr)
	if hp_idx != -1 {
		old_align *= int(data.huge_pages[hp_idx].page_size_in_4k)
	}

	new_align := new_align

	aligned_old_size := mem.align_forward_int(old_size, old_align)
	aligned_new_size  := mem.align_forward_int(new_size, mem.DEFAULT_PAGE_SIZE)
	aligned_new_align := mem.align_forward_int(new_align, mem.DEFAULT_PAGE_SIZE)

	if .Fixed in flags || ((uintptr(aligned_new_align) - 1) & uintptr(old_ptr)) == 0 {
		return_slice := mem.byte_slice(old_ptr, new_size)
		if aligned_old_size == mem.align_forward_int(new_size, old_align){
			if .Uninitialized_Memory not_in flags && new_size > old_size {
				mem.zero_slice(return_slice[old_size:])
			}
			return return_slice, nil
		}

		if _, errno := linux.mremap(old_ptr, uint(old_size), uint(new_size), {}); errno == nil {
			if .Uninitialized_Memory not_in flags && new_size > old_size {
				// zero the remainder of the *old* page
				mem.zero_slice(return_slice[old_size:aligned_old_size])
			}
			if hp_idx != -1 {
				_attempt_huge_page_collapse(old_ptr, new_size)
			}
			return return_slice, nil
		}

		if .Fixed in flags {
			return mem.byte_slice(old_ptr, old_size), .Out_Of_Memory
		}
	}

	// mremap not currently supported for huge pages
	if .Never_Free in flags || aligned_new_align > mem.DEFAULT_PAGE_SIZE {
		new_bytes: []u8
		new_align      = mem.align_forward_int(new_align, mem.DEFAULT_PAGE_SIZE)
		new_bytes, err = page_aligned_alloc(new_size, new_align, offset_pages, flags, data)
		if err != nil {
			return mem.byte_slice(old_ptr, old_size), err
		}

		mem.copy_non_overlapping(&new_bytes[0], old_ptr, old_size)
		if .Never_Free not_in flags {
			linux.munmap(old_ptr, uint(aligned_old_size))
			if hp_idx != -1 {
				unordered_remove(&data.huge_pages, hp_idx)
			}
		}

		return new_bytes[:new_size], nil
	}

	new_ptr, errno := linux.mremap(old_ptr,
	                               uint(aligned_old_size),
	                               uint(aligned_new_size),
	                               {.MAYMOVE})
	if new_ptr == nil || errno != nil {
		return nil, .Out_Of_Memory
	}
	_attempt_huge_page_collapse(new_ptr, new_size)

	return mem.byte_slice(new_ptr, new_size), nil
}

_page_free :: proc(p: rawptr, size: int,
		   flags: Page_Allocator_Flags, data: ^Page_Allocator_Platform_Data) -> Allocator_Error {
	if p == nil || !page_aligned(p) {
		return .Invalid_Pointer
	}
	if .Never_Free in flags {
		return nil
	}
	size := size

	hp_idx := _get_huge_page_idx(data, p)
	if hp_idx != -1 {
		align := mem.DEFAULT_PAGE_SIZE * int(data.huge_pages[hp_idx].page_size_in_4k)
		size = mem.align_forward_int(size, align)
	}
	return linux.munmap(p, uint(size)) == nil ? nil : .Invalid_Pointer
}

_get_huge_page_idx :: proc(data: ^Page_Allocator_Platform_Data, ptr: rawptr) -> int {
	if data == nil {
		return -1
	}

	for hp, i in data.huge_pages {
		if hp.addr == ptr {
			return i
		}
	}
	return -1
}

_attempt_huge_page_collapse :: proc(addr: rawptr, size: int) {
	// If we can fit the aligned section of this allocation into a huge page, try to.
	// We do this in resize because the kernel expects at least one of the pages to be
	// backed by physical memory. Otherwise, it fails with EINVAL.
	if size < HUGE_PAGE_SIZE_DEFAULT {
		return
	}
	aligned_size := mem.align_forward_int(size, HUGE_PAGE_SIZE_DEFAULT)
	huge_page_addr := mem.align_forward(addr, HUGE_PAGE_SIZE_DEFAULT)
	huge_page_size := uintptr(aligned_size) - (uintptr(huge_page_addr) - uintptr(addr))
	if huge_page_size < HUGE_PAGE_SIZE_DEFAULT {
		return
	}

	// This is purely an optimization that attempts to use Transparent Huge Pages (THPs).
	// THPs have the same semantics as regular 4K pages so we don't need to track them.
	_ = linux.madvise(huge_page_addr, uint(huge_page_size), .COLLAPSE)
}
