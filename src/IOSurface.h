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
#ifndef IOKITD_IOSURFACE_H
#define IOKITD_IOSURFACE_H
#include <IOSurface/IOSurfaceDarlingLayout.h>
#include <mach/mach.h>
#include <Foundation/NSDictionary.h>

/* CPU storage only. GPU import is a separate backend requirement. */
class IOSurface {
public:
    explicit IOSurface(NSDictionary *properties);
    ~IOSurface();
    IOSurface(const IOSurface&) = delete;
    IOSurface& operator=(const IOSurface&) = delete;
    const DarlingSurfaceLayout& layout() const { return m_layout; }
    mach_vm_address_t address() const { return m_address; }
    mach_vm_size_t mappedSize() const { return m_mappedSize; }
    uint32_t seed = 0;
    uint32_t exports = 0;
    uint64_t manualUses = 0;
private:
    DarlingSurfaceLayout m_layout{};
    mach_vm_address_t m_address = 0;
    mach_vm_size_t m_mappedSize = 0;
};
#endif
