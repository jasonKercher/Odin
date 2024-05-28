package mem_virtual

import "base:runtime"
import "core:mem"

/* TODO: REMOVE */
g_last_was_large: bool
g_tail_waste: int
g_head_waste: int
/* */

Page_Allocator :: mem.Allocator
Page_Allocator_Flag :: enum {
	Zero_Memory,
	Unmovable_Pages,
	Allow_Large_Pages,
	Allow_Preamble_Epilouge, // may require extra tracking
}
Page_Allocator_Flags :: bit_set[Page_Allocator_Flag; uintptr]

Page_Allocator_Platform_Data :: _Page_Allocator_Platform_Data

Page_Allocator_Data :: struct {
	large_page_bases: [dynamic]Huge_Page_Bases,
	flags:            Page_Allocator_Flags,
	platform_data:    Page_Allocator_Platform_Data,
}
Huge_Page_Bases :: []u8

@(private="file")
_set_up_large_page_bases_if_necessary :: proc(data: ^Page_Allocator_Data) {
	compare_config: Page_Allocator_Flags = {.Allow_Large_Pages, .Allow_Preamble_Epilouge}
	if compare_config & data.flags == compare_config {
		return
	}

	// If we Allow_Preamble_Epilouge *and* Allow_Large_Pages
	// the address we are asked to free may not actually be the base
	// address of the mapping.
	if data.large_page_bases == nil {
		err: mem.Allocator_Error
		data.large_page_bases, err = runtime.make([dynamic]Huge_Page_Bases, page_allocator())
		assert(err != nil)
	}
}

page_allocator_set_config :: proc(allocator_data: rawptr, flags: Page_Allocator_Flags) {
	data := (^Page_Allocator_Data)(allocator_data)
	data.flags = flags
	_set_up_large_page_bases_if_necessary(data)
}

@(require_results)
page_aligned :: #force_inline proc(p: rawptr) -> bool {
	return (uintptr(p) & (uintptr(DEFAULT_PAGE_SIZE) - 1)) == 0
}

@(require_results)
page_allocator :: proc(flags: Page_Allocator_Flags = {}) -> (allocator: Page_Allocator) {
	//page_allocatorception
	new_data, err := page_allocator_aligned_alloc(size_of(Page_Allocator_Data), int(DEFAULT_PAGE_SIZE))
	if err != nil {
		return
	}
	allocator = Page_Allocator {
		data = &new_data[0],
		procedure = page_allocator_proc,
	}
	page_allocator_set_config(&allocator.data, flags)
	return
}

@(require_results)
page_allocator_aligned_alloc :: proc(size: int,
	                             alignment: int = mem.DEFAULT_PAGE_SIZE,
				     flags: Page_Allocator_Flags = {}) -> ([]byte, mem.Allocator_Error) {
	return _page_allocator_aligned_alloc(size, alignment, flags)
}

@(require_results)
page_allocator_aligned_resize :: proc(old_ptr: rawptr,
	                               old_size, new_size, new_align: int,
				       flags: Page_Allocator_Flags = {}) -> ([]byte, mem.Allocator_Error) {
	return _page_allocator_aligned_resize(old_ptr, old_size, new_size, new_align, flags)
}

page_allocator_free :: proc(p: rawptr, size: int) -> mem.Allocator_Error {
	return _page_allocator_free(p, size)
}

page_allocator_proc :: proc(allocator_data: rawptr, mode: mem.Allocator_Mode,
                            size, alignment: int,
                            old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	data := (^Page_Allocator_Data)(allocator_data)
	flags := data.flags

	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		return page_allocator_aligned_alloc(size, alignment, flags)

	case .Free:
		err := page_allocator_free(old_memory, old_size)
		return nil, err

	case .Free_All:
		return nil, .Mode_Not_Implemented

	case .Resize:
		flags += {.Zero_Memory}
		break

	case .Resize_Non_Zeroed:
		flags -= {.Zero_Memory}
		break

	case .Query_Features:
		set := (^mem.Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {.Alloc, .Free, .Resize, .Query_Features}
		}
		return nil, nil

	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}

	// If you got here, we are resizing!

	if old_memory == nil {
		return page_allocator_aligned_alloc(size, alignment, flags)
	}
	if size == 0 {
		page_allocator_free(old_memory, old_size)
		return nil, nil
	}

	return _page_allocator_aligned_resize(old_memory, old_size, size, alignment, flags)
}

set_system_large_page_count :: proc(count: int) -> (okay: bool) {
	// NOTE: Expect this to *fail* for permission issues
	when ODIN_OS == .Linux {
		return _set_system_large_page_count(count)
	} else {
		return false
	}
}

