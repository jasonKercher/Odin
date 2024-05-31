package mem_virtual

import "core:mem"

Page_Allocator_Flag :: enum {
	Static_Pages,
	Allow_Large_Pages,
	Uninitialized_Memory,
}
Page_Allocator_Flags :: bit_set[Page_Allocator_Flag; uintptr]

Page_Allocator :: struct {
	flags: Page_Allocator_Flags,
	platform: Page_Allocator_Platform_Data,
}

@(require_results)
page_aligned :: #force_inline proc(p: rawptr) -> bool {
	return (uintptr(p) & (uintptr(DEFAULT_PAGE_SIZE) - 1)) == 0
}

@(require_results)
page_aligned_alloc :: proc(size: int,
			   alignment: int = mem.DEFAULT_PAGE_SIZE, offset: int = 0,
			   flags: Page_Allocator_Flags = {}, data: ^Page_Allocator_Platform_Data = nil) -> ([]byte, mem.Allocator_Error) {
	if size == 0 {
		return nil, .Invalid_Argument
	}
	return _page_aligned_alloc(size, alignment, offset, flags, data)
}

@(require_results)
page_aligned_resize :: proc(old_ptr: rawptr,
			    old_size, new_size: int,
			    new_align: int = mem.DEFAULT_PAGE_SIZE, offset_pages: int = 0,
			    flags: Page_Allocator_Flags = {}, data: ^Page_Allocator_Platform_Data = nil) -> ([]byte, mem.Allocator_Error) {
	return _page_aligned_resize(old_ptr, old_size, new_size, new_align, offset_pages, flags, data)
}

page_free :: proc(p: rawptr, size: int,
		  flags: Page_Allocator_Flags = {}, data: ^Page_Allocator_Platform_Data = nil) -> mem.Allocator_Error {
	if size <= 0 {
		// NOTE: If you got here using free, try mem.free_with_size.
		//       The page allocator is transient in most cases and
		//       requires a size to infer the original allocation.
		return .Invalid_Argument
	}
	return _page_free(p, size, flags, data)
}

page_allocator_init :: proc(allocator: ^Page_Allocator, flags: Page_Allocator_Flags = {}) {
	allocator.flags = flags
	_page_allocator_init(allocator, flags)
}

@(require_results)
page_allocator :: proc(allocator: ^Page_Allocator = nil) -> mem.Allocator {
	return mem.Allocator {
		procedure = page_allocator_proc,
		data = allocator,
	}
}

page_allocator_proc :: proc(allocator_data: rawptr, mode: mem.Allocator_Mode,
			    size, alignment: int,
			    old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	flags: Page_Allocator_Flags
	platform_data: ^Page_Allocator_Platform_Data
	if allocator := (^Page_Allocator)(allocator_data); allocator != nil {
		flags = allocator.flags
		platform_data = &allocator.platform
	}

	switch mode {
	case .Alloc_Non_Zeroed:
		flags += {.Uninitialized_Memory}
		return page_aligned_alloc(size, alignment, 0, flags, platform_data)

	case .Alloc:
		flags -= {.Uninitialized_Memory}
		return page_aligned_alloc(size, alignment, 0, flags, platform_data)

	case .Free:
		return nil, page_free(old_memory, old_size, flags, platform_data)

	case .Free_All:
		return nil, .Mode_Not_Implemented

	case .Resize_Non_Zeroed:
		flags += {.Uninitialized_Memory}
		break

	case .Resize:
		flags -= {.Uninitialized_Memory}
		break

	case .Query_Features:
		set := (^mem.Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Query_Features}
		}
		return nil, nil

	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}

	// resizing
	if old_memory == nil {
		return page_aligned_alloc(size, alignment, 0, flags, platform_data)
	}
	if size == 0 {
		return nil, page_free(old_memory, old_size, flags, platform_data)
	}
	return page_aligned_resize(old_memory, old_size, size, alignment, 0, flags, platform_data)
}

set_system_large_page_count :: proc(count: int) -> (okay: bool) {
	return _set_system_large_page_count(count)
}

