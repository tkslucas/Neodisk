// UI Automation for a window whose elements are drawn rather than child windows. The Swift side publishes a
// flat element list (parents before children); providers look their element up by id on every call, so one
// that outlived its element or window answers UIA_E_ELEMENTNOTAVAILABLE instead of stale data.

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <ole2.h>
#include <uiautomation.h>

#include <memory>
#include <string>
#include <vector>

#include "CNeodiskWin.h"

namespace {

struct Node {
    int32_t id = 0;
    int32_t parent = 0;
    int32_t role = NDW_ROLE_PANE;
    int32_t flags = 0;
    NdwRect rect = {};
    std::wstring name;
    std::wstring help;
    std::wstring automationId;
    double value = 0;
};

struct State {
    HWND hwnd = nullptr;
    NdwA11yCallbacks callbacks = {};
    std::vector<Node> nodes;
    int32_t rootRole = NDW_ROLE_PANE;
    std::wstring rootName;

    const Node *find(int32_t id) const {
        for (const auto &node : nodes) {
            if (node.id == id) return &node;
        }
        return nullptr;
    }

    bool visible(const Node &node) const { return !(node.flags & NDW_NODE_HIDDEN); }

    std::vector<int32_t> children(int32_t parent) const {
        std::vector<int32_t> result;
        for (const auto &node : nodes) {
            if (node.parent == parent && visible(node)) result.push_back(node.id);
        }
        return result;
    }
};

CONTROLTYPEID controlType(int32_t role) {
    switch (role) {
    case NDW_ROLE_BUTTON: return UIA_ButtonControlTypeId;
    case NDW_ROLE_RADIO: return UIA_RadioButtonControlTypeId;
    case NDW_ROLE_LIST: return UIA_ListControlTypeId;
    case NDW_ROLE_LIST_ITEM: return UIA_ListItemControlTypeId;
    case NDW_ROLE_GROUP: return UIA_GroupControlTypeId;
    case NDW_ROLE_PROGRESS: return UIA_ProgressBarControlTypeId;
    case NDW_ROLE_TEXT: return UIA_TextControlTypeId;
    case NDW_ROLE_TOOLBAR: return UIA_ToolBarControlTypeId;
    case NDW_ROLE_STATUS_BAR: return UIA_StatusBarControlTypeId;
    case NDW_ROLE_SPLITTER: return UIA_ThumbControlTypeId;
    case NDW_ROLE_HEADER: return UIA_HeaderControlTypeId;
    default: return UIA_PaneControlTypeId;
    }
}

BSTR bstr(const std::wstring &text) { return SysAllocStringLen(text.data(), static_cast<UINT>(text.size())); }

class Root;

class Element final : public IRawElementProviderSimple,
                      public IRawElementProviderFragment,
                      public IInvokeProvider,
                      public ISelectionItemProvider,
                      public IRangeValueProvider {
public:
    Element(std::shared_ptr<State> state, int32_t id) : state_(std::move(state)), id_(id) {}

    // IUnknown
    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&refs_); }
    ULONG STDMETHODCALLTYPE Release() override {
        ULONG count = InterlockedDecrement(&refs_);
        if (count == 0) delete this;
        return count;
    }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **out) override {
        if (!out) return E_INVALIDARG;
        *out = nullptr;
        if (riid == __uuidof(IUnknown) || riid == __uuidof(IRawElementProviderSimple)) {
            *out = static_cast<IRawElementProviderSimple *>(this);
        } else if (riid == __uuidof(IRawElementProviderFragment)) {
            *out = static_cast<IRawElementProviderFragment *>(this);
        } else if (riid == __uuidof(IInvokeProvider)) {
            *out = static_cast<IInvokeProvider *>(this);
        } else if (riid == __uuidof(ISelectionItemProvider)) {
            *out = static_cast<ISelectionItemProvider *>(this);
        } else if (riid == __uuidof(IRangeValueProvider)) {
            *out = static_cast<IRangeValueProvider *>(this);
        } else {
            return E_NOINTERFACE;
        }
        AddRef();
        return S_OK;
    }

    // IRawElementProviderSimple
    HRESULT STDMETHODCALLTYPE get_ProviderOptions(ProviderOptions *out) override {
        *out = static_cast<ProviderOptions>(ProviderOptions_ServerSideProvider | ProviderOptions_UseComThreading);
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE GetPatternProvider(PATTERNID pattern, IUnknown **out) override {
        *out = nullptr;
        const Node *node = node_();
        if (!node) return UIA_E_ELEMENTNOTAVAILABLE;
        bool supported = false;
        switch (pattern) {
        case UIA_InvokePatternId:
            supported = node->role == NDW_ROLE_BUTTON || node->role == NDW_ROLE_LIST_ITEM;
            break;
        case UIA_SelectionItemPatternId:
            supported = node->role == NDW_ROLE_RADIO || node->role == NDW_ROLE_LIST_ITEM;
            break;
        case UIA_RangeValuePatternId:
            supported = node->role == NDW_ROLE_PROGRESS;
            break;
        }
        if (supported) {
            *out = static_cast<IRawElementProviderSimple *>(this);
            AddRef();
        }
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE GetPropertyValue(PROPERTYID property, VARIANT *out) override {
        out->vt = VT_EMPTY;
        const Node *node = node_();
        if (!node) return UIA_E_ELEMENTNOTAVAILABLE;
        bool focused = (node->flags & NDW_NODE_FOCUSED) && GetFocus() == state_->hwnd;
        switch (property) {
        case UIA_ControlTypePropertyId:
            out->vt = VT_I4;
            out->lVal = controlType(node->role);
            break;
        case UIA_NamePropertyId:
            out->vt = VT_BSTR;
            out->bstrVal = bstr(node->name);
            break;
        case UIA_HelpTextPropertyId:
            if (!node->help.empty()) {
                out->vt = VT_BSTR;
                out->bstrVal = bstr(node->help);
            }
            break;
        case UIA_AutomationIdPropertyId:
            if (!node->automationId.empty()) {
                out->vt = VT_BSTR;
                out->bstrVal = bstr(node->automationId);
            }
            break;
        case UIA_IsKeyboardFocusablePropertyId:
            out->vt = VT_BOOL;
            out->boolVal = (node->flags & NDW_NODE_FOCUSABLE) && !(node->flags & NDW_NODE_DISABLED) ? VARIANT_TRUE
                                                                                                    : VARIANT_FALSE;
            break;
        case UIA_HasKeyboardFocusPropertyId:
            out->vt = VT_BOOL;
            out->boolVal = focused ? VARIANT_TRUE : VARIANT_FALSE;
            break;
        case UIA_IsEnabledPropertyId:
            out->vt = VT_BOOL;
            out->boolVal = (node->flags & NDW_NODE_DISABLED) ? VARIANT_FALSE : VARIANT_TRUE;
            break;
        case UIA_IsOffscreenPropertyId:
            out->vt = VT_BOOL;
            out->boolVal = (node->rect.w <= 0 || node->rect.h <= 0) ? VARIANT_TRUE : VARIANT_FALSE;
            break;
        case UIA_IsControlElementPropertyId:
        case UIA_IsContentElementPropertyId:
            out->vt = VT_BOOL;
            out->boolVal = VARIANT_TRUE;
            break;
        case UIA_FrameworkIdPropertyId:
            out->vt = VT_BSTR;
            out->bstrVal = SysAllocString(L"Win32");
            break;
        case UIA_ProcessIdPropertyId:
            out->vt = VT_I4;
            out->lVal = static_cast<LONG>(GetCurrentProcessId());
            break;
        }
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE get_HostRawElementProvider(IRawElementProviderSimple **out) override {
        *out = nullptr;
        return S_OK;
    }

    // IRawElementProviderFragment
    HRESULT STDMETHODCALLTYPE Navigate(NavigateDirection direction, IRawElementProviderFragment **out) override;

    HRESULT STDMETHODCALLTYPE GetRuntimeId(SAFEARRAY **out) override {
        *out = nullptr;
        if (!node_()) return UIA_E_ELEMENTNOTAVAILABLE;
        int ids[] = {UiaAppendRuntimeId, id_};
        SAFEARRAY *array = SafeArrayCreateVector(VT_I4, 0, 2);
        if (!array) return E_OUTOFMEMORY;
        for (LONG index = 0; index < 2; index++) SafeArrayPutElement(array, &index, &ids[index]);
        *out = array;
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE get_BoundingRectangle(UiaRect *out) override {
        *out = {};
        const Node *node = node_();
        if (!node) return UIA_E_ELEMENTNOTAVAILABLE;
        POINT origin = {0, 0};
        ClientToScreen(state_->hwnd, &origin);
        *out = {origin.x + node->rect.x, origin.y + node->rect.y, node->rect.w, node->rect.h};
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE GetEmbeddedFragmentRoots(SAFEARRAY **out) override {
        *out = nullptr;
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE SetFocus() override {
        const Node *node = node_();
        if (!node) return UIA_E_ELEMENTNOTAVAILABLE;
        if (state_->callbacks.focus) state_->callbacks.focus(state_->callbacks.context, id_);
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE get_FragmentRoot(IRawElementProviderFragmentRoot **out) override;

    // IInvokeProvider
    HRESULT STDMETHODCALLTYPE Invoke() override {
        const Node *node = node_();
        if (!node) return UIA_E_ELEMENTNOTAVAILABLE;
        if (node->flags & NDW_NODE_DISABLED) return UIA_E_ELEMENTNOTENABLED;
        // The callback defers the action (the pattern asks for asynchrony: it may open a modal dialog).
        if (state_->callbacks.invoke) state_->callbacks.invoke(state_->callbacks.context, id_);
        return S_OK;
    }

    // ISelectionItemProvider
    HRESULT STDMETHODCALLTYPE Select() override { return Invoke(); }
    HRESULT STDMETHODCALLTYPE AddToSelection() override { return Invoke(); }
    HRESULT STDMETHODCALLTYPE RemoveFromSelection() override { return UIA_E_INVALIDOPERATION; }
    HRESULT STDMETHODCALLTYPE get_IsSelected(BOOL *out) override {
        const Node *node = node_();
        if (!node) return UIA_E_ELEMENTNOTAVAILABLE;
        *out = (node->flags & NDW_NODE_SELECTED) ? TRUE : FALSE;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_SelectionContainer(IRawElementProviderSimple **out) override {
        *out = nullptr;
        const Node *node = node_();
        if (!node) return UIA_E_ELEMENTNOTAVAILABLE;
        if (node->parent != 0) {
            *out = new Element(state_, node->parent);
        }
        return S_OK;
    }

    // IRangeValueProvider (read-only progress)
    HRESULT STDMETHODCALLTYPE SetValue(double) override { return UIA_E_INVALIDOPERATION; }
    HRESULT STDMETHODCALLTYPE get_Value(double *out) override {
        const Node *node = node_();
        if (!node) return UIA_E_ELEMENTNOTAVAILABLE;
        *out = node->value;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_IsReadOnly(BOOL *out) override {
        *out = TRUE;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_Maximum(double *out) override {
        *out = 100;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_Minimum(double *out) override {
        *out = 0;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_LargeChange(double *out) override {
        *out = 10;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_SmallChange(double *out) override {
        *out = 1;
        return S_OK;
    }

private:
    const Node *node_() const { return state_->hwnd ? state_->find(id_) : nullptr; }

    std::shared_ptr<State> state_;
    int32_t id_;
    LONG refs_ = 1;
};

class Root final : public IRawElementProviderSimple,
                   public IRawElementProviderFragment,
                   public IRawElementProviderFragmentRoot {
public:
    explicit Root(std::shared_ptr<State> state) : state_(std::move(state)) {}

    ULONG STDMETHODCALLTYPE AddRef() override { return InterlockedIncrement(&refs_); }
    ULONG STDMETHODCALLTYPE Release() override {
        ULONG count = InterlockedDecrement(&refs_);
        if (count == 0) delete this;
        return count;
    }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **out) override {
        if (!out) return E_INVALIDARG;
        *out = nullptr;
        if (riid == __uuidof(IUnknown) || riid == __uuidof(IRawElementProviderSimple)) {
            *out = static_cast<IRawElementProviderSimple *>(this);
        } else if (riid == __uuidof(IRawElementProviderFragment)) {
            *out = static_cast<IRawElementProviderFragment *>(this);
        } else if (riid == __uuidof(IRawElementProviderFragmentRoot)) {
            *out = static_cast<IRawElementProviderFragmentRoot *>(this);
        } else {
            return E_NOINTERFACE;
        }
        AddRef();
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE get_ProviderOptions(ProviderOptions *out) override {
        *out = static_cast<ProviderOptions>(ProviderOptions_ServerSideProvider | ProviderOptions_UseComThreading);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetPatternProvider(PATTERNID, IUnknown **out) override {
        *out = nullptr;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetPropertyValue(PROPERTYID property, VARIANT *out) override {
        out->vt = VT_EMPTY;
        if (!state_->hwnd) return UIA_E_ELEMENTNOTAVAILABLE;
        switch (property) {
        case UIA_ControlTypePropertyId:
            out->vt = VT_I4;
            out->lVal = controlType(state_->rootRole);
            break;
        case UIA_NamePropertyId:
            if (!state_->rootName.empty()) {
                out->vt = VT_BSTR;
                out->bstrVal = bstr(state_->rootName);
            }
            break;
        case UIA_IsKeyboardFocusablePropertyId:
            // Focus lands on the elements inside, not on the container.
            out->vt = VT_BOOL;
            out->boolVal = VARIANT_FALSE;
            break;
        }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_HostRawElementProvider(IRawElementProviderSimple **out) override {
        return UiaHostProviderFromHwnd(state_->hwnd, out);
    }

    HRESULT STDMETHODCALLTYPE Navigate(NavigateDirection direction, IRawElementProviderFragment **out) override {
        *out = nullptr;
        if (!state_->hwnd) return UIA_E_ELEMENTNOTAVAILABLE;
        if (direction == NavigateDirection_FirstChild || direction == NavigateDirection_LastChild) {
            auto children = state_->children(0);
            if (!children.empty()) {
                int32_t id = direction == NavigateDirection_FirstChild ? children.front() : children.back();
                *out = new Element(state_, id);
            }
        }
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetRuntimeId(SAFEARRAY **out) override {
        *out = nullptr;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_BoundingRectangle(UiaRect *out) override {
        *out = {};
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetEmbeddedFragmentRoots(SAFEARRAY **out) override {
        *out = nullptr;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE SetFocus() override {
        ::SetFocus(state_->hwnd);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_FragmentRoot(IRawElementProviderFragmentRoot **out) override {
        *out = this;
        AddRef();
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE ElementProviderFromPoint(double x, double y, IRawElementProviderFragment **out) override {
        *out = nullptr;
        if (!state_->hwnd) return UIA_E_ELEMENTNOTAVAILABLE;
        POINT point = {static_cast<LONG>(x), static_cast<LONG>(y)};
        ScreenToClient(state_->hwnd, &point);
        // Children come after their parents, so the last hit is the deepest.
        int32_t hit = 0;
        for (const auto &node : state_->nodes) {
            if (!state_->visible(node)) continue;
            if (point.x >= node.rect.x && point.x < node.rect.x + node.rect.w && point.y >= node.rect.y &&
                point.y < node.rect.y + node.rect.h) {
                hit = node.id;
            }
        }
        if (hit != 0) *out = new Element(state_, hit);
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE GetFocus(IRawElementProviderFragment **out) override {
        *out = nullptr;
        if (!state_->hwnd) return UIA_E_ELEMENTNOTAVAILABLE;
        for (const auto &node : state_->nodes) {
            if ((node.flags & NDW_NODE_FOCUSED) && state_->visible(node)) {
                *out = new Element(state_, node.id);
                break;
            }
        }
        return S_OK;
    }

private:
    std::shared_ptr<State> state_;
    LONG refs_ = 1;
};

HRESULT Element::Navigate(NavigateDirection direction, IRawElementProviderFragment **out) {
    *out = nullptr;
    const Node *node = node_();
    if (!node) return UIA_E_ELEMENTNOTAVAILABLE;
    switch (direction) {
    case NavigateDirection_Parent:
        if (node->parent == 0) {
            *out = new Root(state_);
        } else {
            *out = new Element(state_, node->parent);
        }
        break;
    case NavigateDirection_NextSibling:
    case NavigateDirection_PreviousSibling: {
        auto siblings = state_->children(node->parent);
        for (size_t index = 0; index < siblings.size(); index++) {
            if (siblings[index] != id_) continue;
            if (direction == NavigateDirection_NextSibling && index + 1 < siblings.size()) {
                *out = new Element(state_, siblings[index + 1]);
            } else if (direction == NavigateDirection_PreviousSibling && index > 0) {
                *out = new Element(state_, siblings[index - 1]);
            }
            break;
        }
        break;
    }
    case NavigateDirection_FirstChild:
    case NavigateDirection_LastChild: {
        auto children = state_->children(id_);
        if (!children.empty()) {
            *out = new Element(state_,
                               direction == NavigateDirection_FirstChild ? children.front() : children.back());
        }
        break;
    }
    }
    return S_OK;
}

HRESULT Element::get_FragmentRoot(IRawElementProviderFragmentRoot **out) {
    *out = nullptr;
    if (!node_()) return UIA_E_ELEMENTNOTAVAILABLE;
    *out = new Root(state_);
    return S_OK;
}

const UINT kRaiseMessage = WM_APP + 0x1A1;
const WPARAM kRaiseFocus = 1;
const WPARAM kRaiseValue = 2;
const WPARAM kRaiseStructure = 3;

std::wstring wide(const uint16_t *text, int32_t length) {
    if (!text || length <= 0) return {};
    return std::wstring(reinterpret_cast<const wchar_t *>(text), static_cast<size_t>(length));
}

} // namespace

struct NdwA11y {
    std::shared_ptr<State> state;
};

extern "C" NdwA11y *ndw_a11y_create(void *hwnd, NdwA11yCallbacks callbacks) {
    auto a11y = new NdwA11y();
    a11y->state = std::make_shared<State>();
    a11y->state->hwnd = static_cast<HWND>(hwnd);
    a11y->state->callbacks = callbacks;
    return a11y;
}

extern "C" void ndw_a11y_set_root(NdwA11y *a11y, int32_t role, const uint16_t *name, int32_t name_length) {
    if (!a11y) return;
    a11y->state->rootRole = role;
    a11y->state->rootName = wide(name, name_length);
}

extern "C" void ndw_a11y_set_nodes(NdwA11y *a11y, const NdwA11yNode *nodes, int32_t count) {
    if (!a11y) return;
    std::vector<Node> copied;
    copied.reserve(count > 0 ? static_cast<size_t>(count) : 0);
    for (int32_t index = 0; index < count; index++) {
        const NdwA11yNode &source = nodes[index];
        Node node;
        node.id = source.id;
        node.parent = source.parent;
        node.role = source.role;
        node.flags = source.flags;
        node.rect = source.rect;
        node.name = wide(source.name, source.name_length);
        node.help = wide(source.help, source.help_length);
        node.automationId = wide(source.automation_id, source.automation_id_length);
        node.value = source.value;
        copied.push_back(std::move(node));
    }
    bool structureChanged = copied.size() != a11y->state->nodes.size();
    for (size_t index = 0; !structureChanged && index < copied.size(); index++) {
        structureChanged = copied[index].id != a11y->state->nodes[index].id;
    }
    a11y->state->nodes = std::move(copied);
    if (structureChanged) PostMessageW(a11y->state->hwnd, kRaiseMessage, kRaiseStructure, 0);
}

extern "C" int32_t ndw_a11y_get_object(NdwA11y *a11y, uintptr_t wparam, intptr_t lparam, intptr_t *result) {
    if (!a11y || static_cast<long>(lparam) != static_cast<long>(UiaRootObjectId)) return 0;
    auto root = new Root(a11y->state);
    *result = UiaReturnRawElementProvider(a11y->state->hwnd, static_cast<WPARAM>(wparam), static_cast<LPARAM>(lparam),
                                          root);
    root->Release();
    return 1;
}

// Events are posted and raised from the window's message handling: raising one makes UI Automation call back
// into the providers, which must not happen in the middle of a model update.
extern "C" void ndw_a11y_focus_changed(NdwA11y *a11y, int32_t id) {
    if (!a11y) return;
    PostMessageW(a11y->state->hwnd, kRaiseMessage, kRaiseFocus, id);
}

extern "C" void ndw_a11y_value_changed(NdwA11y *a11y, int32_t id) {
    if (!a11y) return;
    PostMessageW(a11y->state->hwnd, kRaiseMessage, kRaiseValue, id);
}

extern "C" int32_t ndw_a11y_handle_message(NdwA11y *a11y, uint32_t message, uintptr_t wparam, intptr_t lparam) {
    if (!a11y || message != kRaiseMessage) return 0;
    if (!UiaClientsAreListening() || !a11y->state->hwnd) return 1;
    int32_t id = static_cast<int32_t>(lparam);
    if (wparam == kRaiseStructure) {
        auto root = new Root(a11y->state);
        UiaRaiseStructureChangedEvent(root, StructureChangeType_ChildrenInvalidated, nullptr, 0);
        root->Release();
        return 1;
    }
    const Node *node = a11y->state->find(id);
    if (!node) return 1;
    auto element = new Element(a11y->state, id);
    if (wparam == kRaiseFocus) {
        if (GetFocus() == a11y->state->hwnd) UiaRaiseAutomationEvent(element, UIA_AutomationFocusChangedEventId);
        element->Release();
        return 1;
    }
    VARIANT oldValue = {};
    VARIANT newValue = {};
    if (node->role == NDW_ROLE_PROGRESS) {
        oldValue.vt = VT_EMPTY;
        newValue.vt = VT_R8;
        newValue.dblVal = node->value;
        UiaRaiseAutomationPropertyChangedEvent(element, UIA_RangeValueValuePropertyId, oldValue, newValue);
    } else {
        newValue.vt = VT_BSTR;
        newValue.bstrVal = bstr(node->name);
        UiaRaiseAutomationPropertyChangedEvent(element, UIA_NamePropertyId, oldValue, newValue);
        VariantClear(&newValue);
    }
    element->Release();
    return 1;
}

extern "C" void ndw_a11y_destroy(NdwA11y *a11y) {
    if (!a11y) return;
    HWND hwnd = a11y->state->hwnd;
    a11y->state->hwnd = nullptr;
    a11y->state->nodes.clear();
    // Lets clients drop their references to this window's providers.
    UiaReturnRawElementProvider(hwnd, 0, 0, nullptr);
    delete a11y;
}
