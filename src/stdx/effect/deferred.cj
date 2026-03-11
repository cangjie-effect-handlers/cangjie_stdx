/*
 * Copyright (c) Huawei Technologies Co., Ltd. 2025. All rights reserved.
 * This source file is part of the Cangjie project, licensed under Apache-2.0
 * with Runtime Library Exception.
 *
 * See https://cangjie-lang.cn/pages/LICENSE for license information.
 */

package stdx.effect

internal import std.sync.{AtomicBool, AtomicReference}

private type ThreadHandle = CPointer<Unit>

// Thread-local capture of resumption before request(); read after wake so we never rely on this.resumption after the handler runs.
private class PendingResumptionBox {
    var ref: Option<Object> = None
    init() {}
}
private class PendingResumptionHolder {
    static let PENDING_RESUMPTION_KEY = ThreadLocal<PendingResumptionBox>()
    static func getPendingResumptionBox(): PendingResumptionBox {
        match (PENDING_RESUMPTION_KEY.get()) {
            case Some(box) => box
            case None =>
                let box = PendingResumptionBox()
                PENDING_RESUMPTION_KEY.set(box)
                box
        }
    }
}

// Thread-local capture of frame before ThreadWait(); read after wake so handler never relies on this (frame) after resume.
private class PendingFrameBox {
    var ref: Option<Object> = None
    init() {}
}
private class PendingFrameHolder {
    static let PENDING_FRAME_KEY = ThreadLocal<PendingFrameBox>()
    static func getPendingFrameBox(): PendingFrameBox {
        match (PENDING_FRAME_KEY.get()) {
            case Some(box) => box
            case None =>
                let box = PendingFrameBox()
                PENDING_FRAME_KEY.set(box)
                box
        }
    }
}

@FastNative
foreign func CJ_MRT_GetCurrentCJThread(): ThreadHandle

@FastNative
foreign func CJ_MRT_ThreadWait(): Unit

@FastNative
foreign func CJ_MRT_ThreadResumeAndWait(readyThread: ThreadHandle): Unit

@FastNative
foreign func CJ_MRT_ThreadReady(readyThread: ThreadHandle): Unit

@FastNative
foreign func CJ_MRT_GetCJThreadState(thread: ThreadHandle): Int64

enum HandlerResponse<Res> {
    Resume(Res) | Throw(Exception) | Abort(Error) | Invalid
}

// Box used so handler's write to response is visible to handlee via atomic store/load (memory ordering).
internal class ResponseBox<Res> {
    var r: HandlerResponse<Res> = Invalid
    init(r: HandlerResponse<Res>) {
        this.r = r
    }
}

// Box used so handlee's write to request is visible to handler via atomic store/load (memory ordering).
internal class RequestBox<Ret> {
    var r: HandlerRequest<Ret> = HandlerRequest<Ret>.Invalid
    init(r: HandlerRequest<Ret>) {
        this.r = r
    }
}

extend<Res> HandlerResponse<Res> {
    func unpack<R1>(): R1 {
        match (this) {
            case Resume(r) => (r as R1).getOrThrow()
            case Throw(exn) => throw exn
            case Abort(err) => throw err
            case Invalid => throw Exception("INTERNAL ERROR: invalid handler response")
        }
    }
}

internal class ResumptionInternal<Res, Ret> <: Resumption<Res, Ret> {
    let used = AtomicBool(false)
    let waitingThread = unsafe { CJ_MRT_GetCurrentCJThread() }
    // Response lives here so handlee reads from the same object it holds (this.resumption), avoiding handler-case visibility/corruption.
    var responseHolder = AtomicReference<ResponseBox<Res>>(ResponseBox<Res>(HandlerResponse<Res>.Invalid))
    ResumptionInternal(let handler: DeferredHandlerCase1<Res, Ret>) {}

    func respond(r: HandlerResponse<Res>): Ret {
        // EXECUTED BY HANDLER
        if (this.used.swap(true)) {
            throw DoubleResumeException()
        }
        let box = this.responseHolder.load()
        box.r = r
        this.responseHolder.store(box)
        this.handler.frame.parent = HandlerFrame.getActiveFrame()
        this.handler.frame.handlerThread = unsafe { CJ_MRT_GetCurrentCJThread() }
        unsafe { CJ_MRT_ThreadResumeAndWait(this.waitingThread) }
        this.handler.frame.mainLoop()
    }

    protected func proceed(res: Res): Ret {
        respond(Resume(res))
    }
    protected func fail(err: Error): Ret {
        respond(Abort(err))
    }
    protected func fail(exn: Exception): Ret {
        respond(Throw(exn))
    }
}

type HandlerFn<Cmd, Res, Ret> = (Cmd, ResumptionInternal<Res, Ret>) -> Ret

// We need these intermediate class because there is currently no other way to represent
// the existential types DeferredHandlerCase<_, _, Ret> (used by DeferredFrame<Ret>) and
// DeferredHandlerCase<_, Res, Ret> (used in ResumptionInternal<Res, Ret>)
abstract class DeferredHandlerCase0<Ret> <: HandlerCase {
    protected open func fulfill(): Ret
}

abstract class DeferredHandlerCase1<Res, Ret> <: DeferredHandlerCase0<Ret> {
    DeferredHandlerCase1(let frame: DeferredFrame<Ret>) {}
}

class DeferredHandlerCase<Cmd, Res, Ret> <: DeferredHandlerCase1<Res, Ret> {
    DeferredHandlerCase(frame: DeferredFrame<Ret>, let h: HandlerFn<Cmd, Res, Ret>) {
        super(frame)
    }
    var command: Option<Cmd> = None
    var resumption: Option<ResumptionInternal<Res, Ret>> = None
    protected override func tryHandle<R1>(maybeCmd: Command<R1>, box!: FrameBox): Option<R1> {
        // EXECUTED BY HANDLEE
        match (maybeCmd as Cmd) {
            case Some(cmd) =>
                this.command = cmd
                this.resumption = ResumptionInternal<Res, Ret>(this)
                let resumptionToUse = this.resumption.getOrThrow()
                let pendingBox = PendingResumptionHolder.getPendingResumptionBox()
                pendingBox.ref = (resumptionToUse as Object)
                this.frame.request(Perform(this))
                match (PendingResumptionHolder.getPendingResumptionBox().ref) {
                    case Some(obj) =>
                        pendingBox.ref = None
                        let res = (obj as ResumptionInternal<Res, Ret>).getOrThrow()
                        let resp = res.responseHolder.load()
                        let responseVal = resp.r
                        this.resumption = None
                        responseVal.unpack<R1>()
                    case None => throw Exception("INTERNAL ERROR: missing pending resumption")
                }
            case None => None
        }
    }

    protected override func fulfill(): Ret {
        // EXECUTED BY HANDLER
        let cmd = this.command.getOrThrow()
        this.command = None
        let res = this.resumption.getOrThrow()
        // Do not clear this.resumption here; handlee reads response from res, then respond() clears it.
        this.h(cmd, res)
    }
}

enum HandlerRequest<Ret> {
    Invalid
    | Perform(DeferredHandlerCase0<Ret>)
    | Return(Ret)
    | Throw(Exception)
    | Abort(Error)
}

internal class DeferredFrame<Ret> <: HandlerFrame {
    var handlerThread = unsafe { CJ_MRT_GetCurrentCJThread() }
    var handleeThread = ThreadHandle()
    var requestHolder = AtomicReference<RequestBox<Ret>>(RequestBox<Ret>(HandlerRequest<Ret>.Invalid))

    public DeferredFrame(let fn: () -> Ret) {}
    public func start(): Ret {
        // EXECUTED BY HANDLER
        this.parent = HandlerFrame.getActiveFrame()
        let pendingFrameBox = PendingFrameHolder.getPendingFrameBox()
        pendingFrameBox.ref = (this as Object)
        spawn {
            // EXECUTED BY HANDLEE
            this.handleeThread = unsafe { CJ_MRT_GetCurrentCJThread() }
            HandlerFrame.setActiveFrame(this)
            try {
                this.request(HandlerRequest<Ret>.Return(fn()))
            } catch (exn: Exception) {
                this.request(Throw(exn))
            } catch (err: Error) {
                this.request(Abort(err))
            }
        }
        unsafe { CJ_MRT_ThreadWait() }
        match (PendingFrameHolder.getPendingFrameBox().ref) {
            case Some(obj) =>
                pendingFrameBox.ref = None
                let frame = (obj as DeferredFrame<Ret>).getOrThrow()
                frame.mainLoop()
            case None => throw Exception("INTERNAL ERROR: missing pending frame")
        }
    }

    func mainLoop(): Ret {
        // EXECUTED BY HANDLER
        this.parent = HandlerFrame.getActiveFrame()
        let box = this.requestHolder.load()
        let requestVal = box.r
        match (requestVal) {
            case Perform(handlerCase) => handlerCase.fulfill()
            case Return(ret) =>
                unsafe { CJ_MRT_ThreadReady(handleeThread) }
                this.finalizer()
                ret
            case Throw(exn) =>
                unsafe { CJ_MRT_ThreadReady(handleeThread) }
                this.finalizer()
                throw exn
            case Abort(err) =>
                unsafe { CJ_MRT_ThreadReady(handleeThread) }
                this.finalizer()
                throw err
            case Invalid => throw Exception("INTERNAL ERROR: invalid handler request")
        }
    }

    public func setDeferredHandler<Cmd, Res>(h: HandlerFn<Cmd, Res, Ret>): Unit {
        this.addHandlerCase(DeferredHandlerCase(this, h))
    }

    func request(req: HandlerRequest<Ret>) {
        // EXECUTED BY HANDLEE
        let box = this.requestHolder.load()
        box.r = req
        this.requestHolder.store(box)
        // The number 3 is the internal representation for the "Pending" thread
        // state. The ThreadState method to parse an integer into an explicit enum
        // is not public at time of writing.
        while (3 != unsafe { CJ_MRT_GetCJThreadState(this.handlerThread) }) {
            // Ensure that the handler thread is ready to process the request
            sleep(Duration.Zero)
        }
        unsafe { CJ_MRT_ThreadResumeAndWait(this.handlerThread) }
    }
}
