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
#include "IOSurfaceRoot.h"
#include "IOSurface.h"
#include <IOSurface/IOSurfaceTypes.h>
#include "iokitd.h"
#include <Foundation/NSString.h>
#include <IOKit/IOCFUnserialize.h>
#include <mach/mach_vm.h>
#include <mach/mig_errors.h>
#include <bsm/libbsm.h>
#include <dispatch/private.h>
#include <cstring>
#include <stdexcept>

static void disposeUnresumedSource(dispatch_source_t source) {
    dispatch_source_cancel(source);
    dispatch_resume(source);
    dispatch_release(source);
}

IOSurfaceRoot* IOSurfaceRoot::instance() { static IOSurfaceRoot root; return &root; }
void IOSurfaceRoot::registerSelf(ServiceRegistry *registry) {
    registry->registerService(instance());
    instance()->registerInPlane(kIOServicePlane, "IOSurfaceRoot", IORegistryEntry::root());
}
const char* IOSurfaceRoot::className() const { return "IOSurfaceRoot"; }
NSDictionary* IOSurfaceRoot::matchingDictionary() {
    return @{ @"IOProviderClass": @"IOResources", @"IOClass": @"IOSurfaceRoot",
        @"IOMatchCategory": @"IOSurfaceRoot", @"IOResourceMatch": @"IOBSD" };
}
IOExternalMethod* IOSurfaceRoot::getExternalMethodForIndex(UInt32) {
    /* Scalar IOConnect calls cannot transfer task-local rights. The versioned
     * Darling descriptor protocol is the only enabled surface transport. */
    return nullptr;
}

void IOSurfaceRoot::fillReply(const Mapping& mapping, uint32_t id, DarlingSurfaceReply& r) {
    const auto& s = *mapping.surface;
    r.surfaceID = id; r.layout = s.layout(); r.address = mapping.address;
    r.mappedSize = s.mappedSize(); r.seed = s.seed; r.useCount = mapping.uses;
    r.inUse = s.manualUses != 0 || s.exports != 0;
}
kern_return_t IOSurfaceRoot::mapSurface(Process& p, uint32_t id,
    std::shared_ptr<IOSurface> surface, DarlingSurfaceReply& reply)
{
    auto old = p.mappings.find(id);
    if (old != p.mappings.end() && !old->second.references && !old->second.uses) {
        /* A failed teardown keeps its mapping/storage ownership. Retry before
         * allowing a new wrapper to use this mapping. Task death is the final
         * cleanup boundary if the backend keeps refusing the unmap. */
        kern_return_t cleanup = releaseMapping(p, id);
        if (cleanup != KERN_SUCCESS) return cleanup;
        old = p.mappings.end();
    }
    if (old != p.mappings.end()) {
        if (old->second.references == UINT32_MAX) return KERN_RESOURCE_SHORTAGE;
        ++old->second.references; fillReply(old->second, id, reply); return KERN_SUCCESS;
    }
    Mapping empty;
    empty.surface = std::move(surface);
    /* Allocate bookkeeping before any remote map exists. Zero references mark
     * an unpublished mapping whose rollback remains owned until it succeeds. */
    auto inserted = p.mappings.emplace(id, std::move(empty));
    Mapping& mapping = inserted.first->second;
    vm_prot_t current = 0, maximum = 0;
    kern_return_t result = mach_vm_remap(p.task, &mapping.address, mapping.surface->mappedSize(), 0,
        VM_FLAGS_ANYWHERE, mach_task_self(), mapping.surface->address(), false,
        &current, &maximum, VM_INHERIT_NONE);
    if (result != KERN_SUCCESS) {
        releaseMapping(p, id);
        return result;
    }
    if ((current & (VM_PROT_READ | VM_PROT_WRITE)) != (VM_PROT_READ | VM_PROT_WRITE)) {
        releaseMapping(p, id);
        return KERN_PROTECTION_FAILURE;
    }
    mapping.references = 1;
    fillReply(mapping, id, reply);
    return KERN_SUCCESS;
}
kern_return_t IOSurfaceRoot::releaseMapping(Process& p, uint32_t id) {
    auto it = p.mappings.find(id);
    if (it == p.mappings.end()) return KERN_INVALID_ARGUMENT;
    if (it->second.references && --it->second.references) return KERN_SUCCESS;
    /* Manual uses are per-process, and survive an individual wrapper release. */
    if (it->second.uses) return KERN_SUCCESS;
    auto surface = it->second.surface;
    kern_return_t result = it->second.address ? mach_vm_deallocate(p.task, it->second.address, surface->mappedSize()) : KERN_SUCCESS;
    if (result != KERN_SUCCESS) return result; // retain cleanup ownership for retry/task death
    p.mappings.erase(it);
    surface.reset();
    auto weak = m_surfaces.find(id);
    if (weak != m_surfaces.end() && weak->second.expired()) m_surfaces.erase(weak);
    return KERN_SUCCESS;
}
void IOSurfaceRoot::processDied(mach_port_t task) {
    auto it = m_processes.find(task);
    if (it == m_processes.end()) return;
    for (auto& pair : it->second.mappings) pair.second.surface->manualUses -= pair.second.uses;
    dispatch_source_cancel(it->second.source);
    dispatch_release(it->second.source);
    mach_port_deallocate(mach_task_self(), task);
    m_processes.erase(it);
    for (auto i = m_surfaces.begin(); i != m_surfaces.end();) {
        if (i->second.expired()) i = m_surfaces.erase(i); else ++i;
    }
}
kern_return_t IOSurfaceRoot::exportSurface(const std::shared_ptr<IOSurface>& surface, mach_port_t *right,
    mach_port_t task, uint32_t id, uint64_t generation, bool publicExport) {
    mach_port_t port = MACH_PORT_NULL, previous = MACH_PORT_NULL;
    kern_return_t result = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &port);
    if (result != KERN_SUCCESS) return result;
    result = mach_port_insert_right(mach_task_self(), port, port, MACH_MSG_TYPE_MAKE_SEND);
    if (result != KERN_SUCCESS) { mach_port_destroy(mach_task_self(), port); return result; }
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_MACH_RECV, port, 0, dispatch_get_main_queue());
    if (!source) { mach_port_destroy(mach_task_self(), port); return KERN_RESOURCE_SHORTAGE; }
    result = mach_port_request_notification(mach_task_self(), port, MACH_NOTIFY_NO_SENDERS, 1,
        port, MACH_MSG_TYPE_MAKE_SEND_ONCE, &previous);
    if (MACH_PORT_VALID(previous)) mach_port_deallocate(mach_task_self(), previous);
    if (result != KERN_SUCCESS) {
        disposeUnresumedSource(source); mach_port_destroy(mach_task_self(), port); return result;
    }
    try { m_exports.emplace(port, Export{surface, source, task, id, generation, publicExport}); }
    catch (...) { disposeUnresumedSource(source); mach_port_destroy(mach_task_self(), port); throw; }
    if (publicExport) ++surface->exports;
    dispatch_source_set_event_handler(source, ^{
        dispatch_mig_server(source, sizeof(DarlingSurfaceRequest), iokitAuditDemux);
    });
    dispatch_source_set_cancel_handler(source, ^{ mach_port_destroy(mach_task_self(), port); });
    dispatch_resume(source);
    *right = port; // reply transfers our sole lease/export send right with MOVE_SEND
    return KERN_SUCCESS;
}
void IOSurfaceRoot::exportDied(mach_port_t port) {
    auto it = m_exports.find(port);
    if (it == m_exports.end()) return;
    if (it->second.publicExport) --it->second.surface->exports;
    else {
        auto process = m_processes.find(it->second.task);
        if (process != m_processes.end() && process->second.generation == it->second.generation)
            releaseMapping(process->second, it->second.surfaceID);
    }
    dispatch_source_cancel(it->second.source);
    dispatch_release(it->second.source);
    m_exports.erase(it);
    for (auto weak = m_surfaces.begin(); weak != m_surfaces.end();) {
        if (weak->second.expired()) weak = m_surfaces.erase(weak); else ++weak;
    }
}

kern_return_t IOSurfaceRoot::execute(const DarlingSurfaceRequest& r, DarlingSurfaceReply& reply,
    const audit_token_t& audit, bool& acquiredMapping)
{
    if (!DarlingSurfaceRequestValid(&r)) return KERN_INVALID_ARGUMENT;
    audit_token_t taskAudit{};
    mach_msg_type_number_t count = TASK_AUDIT_TOKEN_COUNT;
    kern_return_t result = task_info(r.task.name, TASK_AUDIT_TOKEN, (task_info_t)&taskAudit, &count);
    if (result != KERN_SUCCESS || count != TASK_AUDIT_TOKEN_COUNT || memcmp(&taskAudit, &audit, sizeof(audit)))
        return KERN_PROTECTION_FAILURE;
    /* A genuine task capability plus this message's audit identity authorizes
     * the target map; an ambient PID alone never authorizes memory access. */
    auto process = m_processes.find(r.task.name);
    if (process == m_processes.end()) {
        if (r.operation != DarlingSurfaceCreate && r.operation != DarlingSurfaceLookupID && r.operation != DarlingSurfaceImport)
            return KERN_INVALID_ARGUMENT;
        if (!m_nextProcessGeneration) return KERN_RESOURCE_SHORTAGE;
        pid_t pid = 0;
        audit_token_to_au32(audit, nullptr, nullptr, nullptr, nullptr, nullptr, &pid, nullptr, nullptr);
        dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, pid, DISPATCH_PROC_EXIT, dispatch_get_main_queue());
        if (!source) return KERN_RESOURCE_SHORTAGE;
        result = mach_port_mod_refs(mach_task_self(), r.task.name, MACH_PORT_RIGHT_SEND, 1);
        if (result != KERN_SUCCESS) { disposeUnresumedSource(source); return result; }
        Process p; p.task = r.task.name; p.source = source; p.generation = m_nextProcessGeneration++;
        try { process = m_processes.emplace(r.task.name, std::move(p)).first; }
        catch (...) { mach_port_deallocate(mach_task_self(), r.task.name); disposeUnresumedSource(source); throw; }
        const mach_port_t task = r.task.name;
        dispatch_source_set_event_handler(source, ^{ processDied(task); });
        dispatch_resume(source);
    }
    Process& p = process->second;
    if (r.operation == DarlingSurfaceCreate || r.operation == DarlingSurfaceLookupID || r.operation == DarlingSurfaceImport) {
        std::shared_ptr<IOSurface> surface;
        uint32_t id = r.surfaceID;
        if (r.operation == DarlingSurfaceCreate) {
            if (!r.propertyLength || !m_nextSurfaceID) return KERN_RESOURCE_SHORTAGE;
            CFStringRef error = nullptr;
            CFTypeRef properties = IOCFUnserializeBinary((const char*)r.properties, r.propertyLength, nullptr, 0, &error);
            if (error) CFRelease(error);
            if (!properties) return KERN_INVALID_ARGUMENT;
            try { surface = std::make_shared<IOSurface>((NSDictionary*)properties); }
            catch (...) { CFRelease(properties); throw; }
            CFRelease(properties);
            id = m_nextSurfaceID++;
        } else if (r.operation == DarlingSurfaceImport) {
            auto exported = m_exports.find(r.capability.name);
            if (exported == m_exports.end() || !exported->second.publicExport) return KERN_INVALID_ARGUMENT;
            surface = exported->second.surface;
            for (const auto& pair : m_surfaces)
                if (pair.second.lock() == surface) { id = pair.first; break; }
            if (!id) return KERN_INVALID_ARGUMENT;
        } else {
            auto it = m_surfaces.find(id);
            if (it == m_surfaces.end() || !(surface = it->second.lock()) || !surface->layout().global)
                return KERN_INVALID_ARGUMENT;
        }
        result = mapSurface(p, id, surface, reply);
        if (result == KERN_SUCCESS) {
            acquiredMapping = true;
            m_surfaces[id] = surface;
            result = exportSurface(surface, &reply.capability.name, p.task, id, p.generation, false);
            /* The real lease right now owns this acquisition, including when
             * a successfully enqueued reply is destroyed without being read. */
            if (result == KERN_SUCCESS) acquiredMapping = false;
        }
        return result;
    }
    auto mapping = p.mappings.find(r.surfaceID);
    if (mapping == p.mappings.end() || !mapping->second.references) return KERN_INVALID_ARGUMENT;
    auto& m = mapping->second;
    auto& s = *m.surface;
    switch (r.operation) {
        case DarlingSurfaceRelease:
            return KERN_NOT_SUPPORTED; // reference ownership is tied to the acquisition lease right
        case DarlingSurfaceExport:
            result = exportSurface(m.surface, &reply.capability.name, MACH_PORT_NULL, r.surfaceID, 0, true);
            if (result != KERN_SUCCESS) return result;
            break;
        case DarlingSurfaceLock:
        case DarlingSurfaceUnlock: {
            if (r.options & ~(kIOSurfaceLockReadOnly | kIOSurfaceLockAvoidSync)) return KERN_INVALID_ARGUMENT;
            uint32_t& locks = (r.options & kIOSurfaceLockReadOnly) ? m.readLocks : m.writeLocks;
            if (r.operation == DarlingSurfaceLock) {
                if (locks == UINT32_MAX) return KERN_RESOURCE_SHORTAGE;
                ++locks;
            } else {
                if (!locks) return KERN_INVALID_ARGUMENT;
                --locks;
                if (!(r.options & kIOSurfaceLockReadOnly)) ++s.seed;
            }
            /* CPU-only MAP_SHARED storage requires no GPU readback. */
            break;
        }
        case DarlingSurfaceUseIncrement:
            if (m.uses == INT32_MAX) return KERN_RESOURCE_SHORTAGE;
            ++m.uses; ++s.manualUses; break;
        case DarlingSurfaceUseDecrement:
            if (!m.uses) return KERN_INVALID_ARGUMENT;
            --m.uses; --s.manualUses; break;
        case DarlingSurfaceState: break;
        default: return KERN_INVALID_ARGUMENT;
    }
    fillReply(m, r.surfaceID, reply);
    return KERN_SUCCESS;
}

bool IOSurfaceRoot::handleMessage(mach_msg_header_t *header, mach_msg_header_t *output, const audit_token_t& audit)
{
    if (header->msgh_id == MACH_NOTIFY_NO_SENDERS && m_exports.count(header->msgh_local_port)) {
        mach_port_status_t status{};
        mach_msg_type_number_t count = MACH_PORT_RECEIVE_STATUS_COUNT;
        if (header->msgh_size == sizeof(mach_no_senders_notification_t) &&
            !(header->msgh_bits & MACH_MSGH_BITS_COMPLEX) &&
            mach_port_get_attributes(mach_task_self(), header->msgh_local_port, MACH_PORT_RECEIVE_STATUS,
                (mach_port_info_t)&status, &count) == KERN_SUCCESS && !status.mps_srights)
            exportDied(header->msgh_local_port);
        mach_msg_destroy(header);
        auto *noReply = (mig_reply_error_t*)output;
        memset(noReply, 0, sizeof(*noReply)); noReply->RetCode = MIG_NO_REPLY;
        return true;
    }
    if (header->msgh_id != DARLING_SURFACE_MSG_ID) return false;
    DarlingSurfaceReply reply{};
    reply.header.msgh_bits = MACH_MSGH_BITS(MACH_MSGH_BITS_REMOTE(header->msgh_bits), 0) | MACH_MSGH_BITS_COMPLEX;
    reply.header.msgh_remote_port = header->msgh_remote_port;
    reply.header.msgh_size = sizeof(reply); reply.header.msgh_id = DARLING_SURFACE_MSG_ID + 100;
    reply.body.msgh_descriptor_count = 1; reply.capability.type = MACH_MSG_PORT_DESCRIPTOR;
    reply.capability.disposition = MACH_MSG_TYPE_MOVE_SEND; reply.ndr = NDR_record;
    reply.version = DARLING_SURFACE_LAYOUT_VERSION;
    bool acquired = false;
    try {
        reply.result = header->msgh_local_port == port() && header->msgh_size == sizeof(DarlingSurfaceRequest) ?
            execute(*(const DarlingSurfaceRequest*)header, reply, audit, acquired) : KERN_INVALID_ARGUMENT;
    } catch (const std::bad_alloc&) { reply.result = KERN_RESOURCE_SHORTAGE; }
      catch (const std::exception&) { reply.result = KERN_INVALID_ARGUMENT; }
    const mach_port_t task = header->msgh_size == sizeof(DarlingSurfaceRequest) ? ((DarlingSurfaceRequest*)header)->task.name : MACH_PORT_NULL;
    if (acquired && reply.result != KERN_SUCCESS) {
        auto p = m_processes.find(task);
        if (p != m_processes.end()) releaseMapping(p->second, reply.surfaceID);
        acquired = false;
    }
    /* Consume every incoming descriptor on both success and malformed input.
     * Save the reply right first; dispatch_mig_server must not destroy it twice. */
    header->msgh_remote_port = MACH_PORT_NULL;
    mach_msg_destroy(header);
    mach_msg_return_t sent = mach_msg(&reply.header, MACH_SEND_MSG | MACH_SEND_TIMEOUT,
        sizeof(reply), 0, MACH_PORT_NULL, 1000, MACH_PORT_NULL);
    if (sent != MACH_MSG_SUCCESS) {
        mach_msg_destroy(&reply.header);
        if (acquired) {
            auto p = m_processes.find(task);
            if (p != m_processes.end()) releaseMapping(p->second, reply.surfaceID);
        }
    }
    auto *noReply = (mig_reply_error_t*)output;
    memset(noReply, 0, sizeof(*noReply)); noReply->RetCode = MIG_NO_REPLY;
    return true;
}
