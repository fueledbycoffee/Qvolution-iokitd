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

#ifndef IOKITD_IOSURFACEROOT_H
#define IOKITD_IOSURFACEROOT_H
#include "IOUserClient.h"
#include "ServiceRegistry.h"
#include <IOSurface/IOSurfaceDarlingIPC.h>
#include <unordered_map>
#include <memory>
#include <dispatch/dispatch.h>
class IOSurface;
class IOSurfaceRoot : public IOUserClient {
public:
    const char* className() const override;
    NSDictionary* matchingDictionary() override;
    IOExternalMethod *getExternalMethodForIndex(UInt32 index) override;
    static IOSurfaceRoot* instance();
    static void registerSelf(ServiceRegistry* registry);
    bool handleMessage(mach_msg_header_t *request, mach_msg_header_t *reply, const audit_token_t& audit);
private:
    struct Mapping {
        std::shared_ptr<IOSurface> surface;
        mach_vm_address_t address = 0;
        uint32_t references = 0, uses = 0;
        uint32_t readLocks = 0, writeLocks = 0;
    };
    struct Process {
        mach_port_t task = MACH_PORT_NULL;
        uint64_t generation = 0;
        dispatch_source_t source = nullptr;
        std::unordered_map<uint32_t, Mapping> mappings;
    };
    struct Export {
        std::shared_ptr<IOSurface> surface;
        dispatch_source_t source;
        mach_port_t task;
        uint32_t surfaceID;
        uint64_t generation;
        bool publicExport;
    };
    kern_return_t execute(const DarlingSurfaceRequest&, DarlingSurfaceReply&, const audit_token_t&,
        bool& acquiredMapping);
    kern_return_t mapSurface(Process&, uint32_t id, std::shared_ptr<IOSurface>, DarlingSurfaceReply&);
    void fillReply(const Mapping&, uint32_t id, DarlingSurfaceReply&);
    kern_return_t releaseMapping(Process&, uint32_t id);
    void processDied(mach_port_t task);
    kern_return_t exportSurface(const std::shared_ptr<IOSurface>&, mach_port_t *right,
        mach_port_t task, uint32_t id, uint64_t generation, bool publicExport);
    void exportDied(mach_port_t port);
    std::unordered_map<mach_port_t, Process> m_processes;
    std::unordered_map<uint32_t, std::weak_ptr<IOSurface>> m_surfaces;
    std::unordered_map<mach_port_t, Export> m_exports;
    uint32_t m_nextSurfaceID = 1;
    uint64_t m_nextProcessGeneration = 1;
};
#endif
