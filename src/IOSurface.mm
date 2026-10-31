/*
 This file is part of Darling.

 Copyright (C) 2020 Lubos Dolezel

 Darling is free software: you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation, either version 3 of the License, or
 (at your option) any later version.

 Darling is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with Darling.  If not, see <http://www.gnu.org/licenses/>.
*/
#include "IOSurface.h"
#include <IOSurface/IOSurfaceRef.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_vm.h>
#include <unistd.h>
#include <stdexcept>
#include <new>

static uint64_t number(CFDictionaryRef d, CFStringRef key, uint64_t fallback, bool required = false)
{
    CFTypeRef value = CFDictionaryGetValue(d, key);
    if (!value) {
        if (required) throw std::invalid_argument("missing surface property");
        return fallback;
    }
    int64_t result;
    if (CFGetTypeID(value) != CFNumberGetTypeID() || CFNumberIsFloatType((CFNumberRef)value) ||
        !CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &result) || result < 0)
        throw std::invalid_argument("invalid integer surface property");
    return (uint64_t)result;
}
static uint32_t number32(CFDictionaryRef d, CFStringRef key, uint64_t fallback, bool required = false)
{
    uint64_t n = number(d, key, fallback, required);
    if (n > UINT32_MAX) throw std::invalid_argument("surface property exceeds representation");
    return (uint32_t)n;
}
static uint64_t add(uint64_t a, uint64_t b)
{
    if (b > UINT64_MAX - a) throw std::invalid_argument("surface layout overflow");
    return a + b;
}
static void unitGeometry(CFDictionaryRef d, bool plane)
{
    if (number(d, plane ? kIOSurfacePlaneElementWidth : kIOSurfaceElementWidth, 1) != 1 ||
        number(d, plane ? kIOSurfacePlaneElementHeight : kIOSurfaceElementHeight, 1) != 1 ||
        (plane && CFDictionaryContainsKey(d, kIOSurfacePlaneBase)))
        throw std::invalid_argument("unsupported surface element geometry");
}
static DarlingSurfaceLayout parseLayout(CFDictionaryRef d)
{
    if (!d || CFGetTypeID(d) != CFDictionaryGetTypeID())
        throw std::invalid_argument("surface properties must be a dictionary");
    DarlingSurfaceLayout l{};
    l.version = DARLING_SURFACE_LAYOUT_VERSION;
    l.width = number32(d, kIOSurfaceWidth, 0, true);
    l.height = number32(d, kIOSurfaceHeight, 0, true);
    l.pixelFormat = number32(d, kIOSurfacePixelFormat, 0, true);
    CFTypeRef global = CFDictionaryGetValue(d, kIOSurfaceIsGlobal);
    if (global && CFGetTypeID(global) != CFBooleanGetTypeID())
        throw std::invalid_argument("surface global property must be Boolean");
    l.global = global == kCFBooleanTrue;
    unitGeometry(d, false);
    CFTypeRef planes = CFDictionaryGetValue(d, kIOSurfacePlaneInfo);
    if (planes) {
        if (CFGetTypeID(planes) != CFArrayGetTypeID() || CFArrayGetCount((CFArrayRef)planes) != 2 ||
            l.pixelFormat != DARLING_SURFACE_420V)
            throw std::invalid_argument("unsupported surface planes");
        l.planeCount = 2;
        uint64_t nextOffset = 0;
        for (unsigned i = 0; i < 2; ++i) {
            CFDictionaryRef p = (CFDictionaryRef)CFArrayGetValueAtIndex((CFArrayRef)planes, i);
            if (!p || CFGetTypeID(p) != CFDictionaryGetTypeID())
                throw std::invalid_argument("surface plane must be a dictionary");
            unitGeometry(p, true);
            auto& out = l.planes[i];
            out.width = number32(p, kIOSurfacePlaneWidth, 0, true);
            out.height = number32(p, kIOSurfacePlaneHeight, 0, true);
            out.bytesPerElement = number32(p, kIOSurfacePlaneBytesPerElement, i ? 2 : 1);
            out.bytesPerRow = number32(p, kIOSurfacePlaneBytesPerRow,
                (uint64_t)out.width * out.bytesPerElement);
            out.offset = number(p, kIOSurfacePlaneOffset, nextOffset);
            out.size = number(p, kIOSurfacePlaneSize, (uint64_t)out.height * out.bytesPerRow);
            nextOffset = add(out.offset, out.size);
        }
        /* Validate supplied top-level geometry too; it cannot contradict plane 0. */
        if (number(d, kIOSurfaceBytesPerElement, 1) != 1 ||
            number(d, kIOSurfaceBytesPerRow, l.planes[0].bytesPerRow) != l.planes[0].bytesPerRow ||
            number(d, kIOSurfaceOffset, 0) != 0)
            throw std::invalid_argument("inconsistent planar surface geometry");
        l.allocationSize = number(d, kIOSurfaceAllocSize, nextOffset);
    } else {
        if (l.pixelFormat != DARLING_SURFACE_BGRA)
            throw std::invalid_argument("unsupported packed surface format");
        auto& p = l.planes[0];
        p.width = l.width; p.height = l.height;
        p.bytesPerElement = number32(d, kIOSurfaceBytesPerElement, 4);
        p.bytesPerRow = number32(d, kIOSurfaceBytesPerRow, (uint64_t)p.width * p.bytesPerElement);
        p.offset = number(d, kIOSurfaceOffset, 0);
        p.size = (uint64_t)p.height * p.bytesPerRow;
        l.allocationSize = number(d, kIOSurfaceAllocSize, add(p.offset, p.size));
    }
    if (!DarlingSurfaceLayoutValid(&l)) throw std::invalid_argument("invalid surface layout");
    return l;
}

IOSurface::IOSurface(NSDictionary *properties)
: m_layout(parseLayout((CFDictionaryRef)properties))
{
    const uint64_t page = (uint64_t)getpagesize();
    if (m_layout.allocationSize > UINT64_MAX - (page - 1))
        throw std::invalid_argument("surface page rounding overflow");
    m_mappedSize = (m_layout.allocationSize + page - 1) / page * page;
    if (mach_vm_allocate(mach_task_self(), &m_address, m_mappedSize, VM_FLAGS_ANYWHERE) != KERN_SUCCESS)
        throw std::bad_alloc();
    /* The allocation remains unpublished until its first shared remap succeeds. */
}
IOSurface::~IOSurface()
{
    if (m_address) mach_vm_deallocate(mach_task_self(), m_address, m_mappedSize);
}
