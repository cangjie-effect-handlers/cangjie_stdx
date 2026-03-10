# Bugfix: Deferred effect handler response/request visibility and segfaults

## Summary

This document describes a fix for intermittent **INTERNAL ERROR: invalid handler response** / **invalid handler request** and **segfaults** in the deferred effect implementation (`stdx/effect/deferred.cj`). The fix has four parts: (1) making the handler response visible across threads using atomic reference and a response box, (2) storing the response on the resumption object and reading it via a thread-local so the handlee never relies on the handler-case object after wake-up, (3) the same visibility and thread-local pattern for the **Request** path and for the **handler** after it wakes from `ThreadWait()`, and (4) Cangjie-specific type and enum ordering details.

- **Request path:** The handlee’s write to the request must be visible to the handler. The frame holds the request in a `RequestBox<Ret>` inside an `AtomicReference` (`requestHolder`). The handlee loads the box, sets `box.r = req`, stores the box, then resumes the handler; the handler reads via `requestHolder.load()` and `box.r`. No separate “requestReady” flag is used—synchronization is from the atomic store/load of the box only.

- **Handler wake segfaults:** After the handler thread is resumed from `CJ_MRT_ThreadWait()` in `start()`, using `this` (the `DeferredFrame`) can be unsafe. The handler stores the frame in a **thread-local** (`PendingFrameBox` / `PendingFrameHolder`) before waiting, and after wake retrieves the frame from the thread-local and calls `frame.mainLoop()` instead of `this.mainLoop()`.

---

## Original code (pre-fix)

The **original** implementation had:

- On the **handler case** (e.g. `DeferredHandlerCase1` / `DeferredHandlerCase`): a single field **`var response: HandlerResponse<Res> = Invalid`**. There was **no `responseReady`** field.
- The handler set `this.handler.response = r` and then called `CJ_MRT_ThreadResumeAndWait(this.waitingThread)`.
- The handlee, after returning from `request(Perform(this))`, read `this.response` and called `this.response.unpack<R1>()`.

So the handlee relied on a plain (non-atomic) write to `response` on another thread, with no additional synchronization.

---

## Root cause (for humans)

### What was going wrong

1. **INTERNAL ERROR (Invalid response)**  
   The handler sets `response = Resume(...)` and resumes the handlee. Sometimes the handlee still read `response == Invalid`, so `unpack()` threw INTERNAL ERROR. The **write to `response` was not always visible** to the handlee. That’s a **memory visibility** issue: a plain (non-atomic) field written on one thread is not guaranteed to be seen by another thread; without a synchronizing operation (e.g. an atomic store/load or barrier), the handlee can see a stale value. The original code had no `responseReady` or other atomic to enforce ordering.

2. **Segfaults after “request() returned”**  
   After moving the response into an atomic reference and a shared box, the handlee sometimes crashed when reading the response (e.g. when loading from `this.responseHolder` or accessing the loaded object). So in addition to visibility, there was a **correctness/lifetime** issue: after the handlee is resumed, using **`this` (the handler case)** or **`this.responseHolder` / `this.resumption`** to reach the response could be unsafe (wrong object, torn state, or bad reference). The fix is to **never depend on the handler-case or its fields after the wake**: the handlee must get the resumption (and thus the response) from a **thread-local** that was set **before** calling `request()`.

3. **Segfaults after handler wake**  
   The handler thread blocks in `start()` on `CJ_MRT_ThreadWait()`. When the handlee resumes it, the handler continues and originally called `this.mainLoop()`. Using **`this` (the frame)** after wake can be similarly unsafe. The fix is to store the frame in a **thread-local** before `ThreadWait()` and, after wake, retrieve the frame from the thread-local and call `frame.mainLoop()` instead of using `this`.

---

## The fix (for agents and humans)

Apply the following in `deferred.cj` (package `stdx.effect`).

### 1. Imports

Ensure the file has:

```cangjie
internal import std.sync.{AtomicBool, AtomicReference}
```

(Add `AtomicReference` if the old version only imports `AtomicBool`.)

---

### 2. Thread-local for pending resumption

**Purpose:** The handlee must not read `this.resumption` (or any handler-case state) after it is resumed. It must use a resumption reference that it stored in its own thread before blocking.

Add these declarations **after** `private type ThreadHandle = ...` and **before** the `@FastNative` / `foreign func` block:

- A box type holding an optional object reference:
  - `PendingResumptionBox`: class with `var ref: Option<Object> = None` and `init() {}`.
- A holder type with a static thread-local and getter:
  - `PendingResumptionHolder`: class with:
    - `static let PENDING_RESUMPTION_KEY = ThreadLocal<PendingResumptionBox>()`
    - `static func getPendingResumptionBox(): PendingResumptionBox` that: if the thread-local has a box, return it; else create a new `PendingResumptionBox`, set it on the thread-local, and return it.

Mark both classes `private` so they are implementation detail.

---

### 2b. Thread-local for pending frame (handler)

**Purpose:** The handler must not use `this` (the `DeferredFrame`) after it is resumed from `ThreadWait()`. It must use a frame reference that it stored in its own thread before blocking.

Add (after the resumption thread-local types, before `@FastNative`):

- `PendingFrameBox`: class with `var ref: Option<Object> = None` and `init() {}`.
- `PendingFrameHolder`: class with:
  - `static let PENDING_FRAME_KEY = ThreadLocal<PendingFrameBox>()`
  - `static func getPendingFrameBox(): PendingFrameBox` (same pattern as `getPendingResumptionBox()`).

Mark both classes `private`.

---

### 3. Response type and box (memory ordering)

**Purpose:** The handler’s write to the response must be visible to the handlee. Use a **single** response value stored in a **reference type** and communicate it via **atomic store/load** so the runtime’s memory model orders the handler’s write before the handlee’s read.

- **HandlerResponse enum:**  
  Keep as is (e.g. `Resume(Res) | Throw(Exception) | Abort(Error) | Invalid`). Do **not** reorder variants for this fix; if you need to disambiguate `Invalid` from another enum, use qualified names (e.g. `HandlerResponse<Res>.Invalid`) at use sites.

- **ResponseBox<Res>:**  
  Add an internal class:
  - Field: `var r: HandlerResponse<Res> = HandlerResponse<Res>.Invalid`
  - Constructor: `init(r: HandlerResponse<Res>) { this.r = r }`  
  So the handler can do: load the box, set `box.r = r`, then store the same box reference (for ordering).

- **HandlerResponse.unpack<R1>():**
  - Keep the existing match; in the `Invalid` case, only throw `Exception("INTERNAL ERROR: invalid handler response")` (no debug prints).

---

### 4. ResumptionInternal: hold response and use same box

**Purpose:** The response is stored on the **resumption** object (same object the handlee will later read via thread-local), and the handler updates the **same** box reference (no per-call allocation) for correct memory ordering. No separate “responseReady” flag is used—synchronization is from the atomic store/load of the box only.

- **Fields on ResumptionInternal<Res, Ret>:**
  - Keep: `used`, `waitingThread`, and constructor taking the handler case.
  - **Add:** `var responseHolder = AtomicReference<ResponseBox<Res>>(ResponseBox<Res>(HandlerResponse<Res>.Invalid))`

- **respond(r: HandlerResponse<Res>):**
  - Check double-resume with `this.used.swap(true)` as before.
  - Then: `let box = this.responseHolder.load()`, `box.r = r`, `this.responseHolder.store(box)`.
  - Then set frame parent and handler thread, call `CJ_MRT_ThreadResumeAndWait(this.waitingThread)`, then `this.handler.frame.mainLoop()`.
  - Do **not** write or read response on the handler case; only on `this` (ResumptionInternal).

---

### 5. DeferredHandlerCase1: remove response state

- **Remove** from `DeferredHandlerCase1<Res, Ret>` the **`response`** field. After the fix, only `ResumptionInternal` holds response state (`responseHolder`).

---

### 6. DeferredHandlerCase.tryHandle: thread-local and resumption-only read

**Purpose:** After `request(Perform(this))` returns, the handlee must **not** use `this` (handler case) to find the resumption or the response. It must use the resumption reference stored in thread-local before the call.

In the branch where the command is `Some(cmd)`:

1. **Before** `this.frame.request(Perform(this))`:
   - `let resumptionToUse = this.resumption.getOrThrow()`
   - `let pendingBox = PendingResumptionHolder.getPendingResumptionBox()`
   - `pendingBox.ref = (resumptionToUse as Object)`  
   (In Cangjie, `(x as Object)` can be an optional cast; assign directly to `ref` without wrapping in `Some(...)` if the type is already `Option<Object>`.)

2. Call `this.frame.request(Perform(this))` as usual.

3. **After** `request(...)` returns:
   - Get the resumption from the thread-local, **not** from `this.resumption`:
     - `match (PendingResumptionHolder.getPendingResumptionBox().ref)`:
       - `case Some(obj)`:
         - Set `pendingBox.ref = None`.
         - `let res = (obj as ResumptionInternal<Res, Ret>).getOrThrow()`  
           (If the cast returns an option type, use `.getOrThrow()` so `res` is `ResumptionInternal<Res, Ret>`.)
         - `let resp = res.responseHolder.load()`
         - `let responseVal = resp.r`
         - Clear handler-case state: `this.resumption = None`
         - Return `Some(responseVal.unpack<R1>())`.
       - `case None`: throw an exception (e.g. "INTERNAL ERROR: missing pending resumption").

So the handlee never touches handler-case response state; it only uses the resumption reference stored in the thread-local and then reads `res.responseHolder` and `resp.r`.

---

### 7. fulfill(): do not clear resumption before calling the handler

- In `fulfill()`, do **not** set `this.resumption = None` before calling `this.h(cmd, res)`.
- The handlee will clear `this.resumption` after it has read the response (see step 6). This keeps the resumption reference valid for the handlee until it has finished reading the response from it (via the thread-local).

---

### 8. Request path: RequestBox and requestHolder

**Purpose:** The handlee’s write to the request must be visible to the handler. Use the same pattern as Response: a box in an atomic reference. No separate “requestReady” flag—synchronization is from the atomic store/load of the box only.

- **RequestBox<Ret>:** Internal class with `var r: HandlerRequest<Ret> = HandlerRequest<Ret>.Invalid` and `init(r: HandlerRequest<Ret>) { this.r = r }`.

- **DeferredFrame<Ret>:** Replace the plain `handlerRequest` field with:
  - `var requestHolder = AtomicReference<RequestBox<Ret>>(RequestBox<Ret>(HandlerRequest<Ret>.Invalid))`

- **request(req: HandlerRequest<Ret>)** (handlee): `let box = this.requestHolder.load()`, `box.r = req`, `this.requestHolder.store(box)`, then the existing wait loop and `CJ_MRT_ThreadResumeAndWait(this.handlerThread)`.

- **mainLoop()** (handler): Read the request from the atomic, not from a plain field: `let box = this.requestHolder.load()`, `let requestVal = box.r`, then `match (requestVal) { ... }`.

---

### 9. start(): frame in thread-local before and after ThreadWait

**Purpose:** After the handler is resumed from `CJ_MRT_ThreadWait()`, do not use `this` (the frame). Use the frame reference stored in the handler’s thread-local before the wait.

- **Before** `unsafe { CJ_MRT_ThreadWait() }` in `start()`:
  - `let pendingFrameBox = PendingFrameHolder.getPendingFrameBox()`
  - `pendingFrameBox.ref = (this as Object)`

- **After** `CJ_MRT_ThreadWait()` returns:
  - Do **not** call `this.mainLoop()`.
  - `match (PendingFrameHolder.getPendingFrameBox().ref)`:
    - `case Some(obj)`: set `pendingFrameBox.ref = None`, `let frame = (obj as DeferredFrame<Ret>).getOrThrow()`, then `frame.mainLoop()` (and return its result).
    - `case None`: throw `Exception("INTERNAL ERROR: missing pending frame")`.

---

### 10. Enum and type quirks (Cangjie)

- **Invalid disambiguation:**  
  If the compiler reports “multiple constructor 'Invalid'”, both `HandlerResponse<Res>` and `HandlerRequest<Ret>` may define `Invalid`. At use sites, use the fully qualified variant, e.g. `HandlerResponse<Res>.Invalid` and `HandlerRequest<Ret>.Invalid` where needed (e.g. initial values for `ResponseBox`, `RequestBox`, and request holder).

- **HandlerRequest enum order:**  
  Keep `Invalid` as the **last** variant of `HandlerRequest<Ret>` (e.g. `| Perform(...) | Return(...) | Throw(...) | Abort(...) Invalid`) so that the original enum order is preserved and qualified names still resolve correctly.

- **Option / cast types:**  
  If `(x as Object)` is already `Option<Object>`, assign it directly to `pendingBox.ref` without wrapping in `Some(...)`. If `(obj as ResumptionInternal<Res, Ret>)` or `(obj as DeferredFrame<Ret>)` is typed as an option, call `.getOrThrow()` so you get the concrete type and can access `responseHolder` or call `frame.mainLoop()`.

---

## Reasoning (for humans)

1. **Atomic reference + box:**  
   The handler must make its write to the response visible to the handlee. Using an atomic store (of the box reference) after writing `box.r`, and an atomic load on the handlee side, establishes a synchronizes-with relationship so the handlee sees the updated `box.r`.

2. **Same box, no extra allocation:**  
   Reusing one box per resumption (load box, set `box.r = r`, store same box) avoids allocating per response and keeps a single live reference, which avoids use-after-free or wrong-object issues from swapping in a new box.

3. **Response on ResumptionInternal:**  
   Storing the response on the resumption object (the same object both threads use) keeps a single place for the result and avoids relying on handler-case fields that might be in a bad or confusing state after resume.

4. **Thread-local for resumption reference:**  
   After the handlee is resumed, we do not trust `this` (handler case) or `this.resumption` to still be the correct reference (e.g. due to reordering, multiple cases, or runtime behavior). By saving the resumption in a thread-local **before** blocking and reading it **after** wake, the handlee always uses the reference it stored itself, so it never depends on handler-case state post-resume and the segfaults from bad references go away.

5. **Not clearing resumption in fulfill():**  
   The handlee needs to reach the same resumption object after wake; that reference is stored in the thread-local before `request()`. We only clear `this.resumption` on the handlee side after the response has been read, so the object remains valid for the duration of the read.

6. **Request path: atomic box only.**  
   Same as response: the handlee’s write is made visible to the handler by storing the request in a box and using an atomic store (of the box) after writing `box.r`. No separate “requestReady” (or “responseReady”) flag is used; the atomic load/store of the box provides the necessary synchronization.

7. **Thread-local for handler frame after wake:**  
   After the handler thread is resumed from `ThreadWait()`, we do not trust `this` (the frame) to be a valid reference. By storing the frame in a thread-local before the wait and reading it after wake, the handler always uses the reference it stored itself, avoiding segfaults from a bad or torn frame reference.

---

## Files touched

- **`cangjie_stdx/src/stdx/effect/deferred.cj`**  
  All changes are in this file: thread-local types (PendingResumptionBox/Holder, PendingFrameBox/Holder), ResponseBox and RequestBox, ResumptionInternal.responseHolder, DeferredFrame.requestHolder, tryHandle and fulfill logic, request() and mainLoop() for the request path, start() frame thread-local before/after ThreadWait, and any enum/type adjustments above.

---

## Verification

- Build: `cjpm build`.
- Run tests or scenarios that use deferred effects (e.g. resumptions over the network). You should no longer see INTERNAL ERROR from “invalid handler response” or “invalid handler request”, or segfaults in `tryHandle` after “request() returned” or in the handler after wake from `ThreadWait()`.
- Do not add debug prints or change enum variant order except as specified (keep `HandlerRequest` with `Invalid` last).
