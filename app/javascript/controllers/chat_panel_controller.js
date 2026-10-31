import { Controller } from "@hotwired/stimulus";

const DIALOG_ID = "ai-chat-panel";

// Turbo's permanent-element transfer preserves the dialog and its `open`
// attribute but drops the top-layer modal state. Re-open it so focus
// containment, background inertness, and Escape-to-close keep working.
// This lives outside the controller because Turbo also replaces the wrapper
// element on a visit, so a per-element listener can disappear with it.
function restoreModalState(dialog) {
  if (!dialog?.open || dialog.matches(":modal")) return;

  dialog.close();
  dialog.showModal();
}

function syncLauncherExpandedState(dialog) {
  const launcher = document.querySelector(
    "[data-chat-panel-target='launcher']"
  );
  launcher?.setAttribute("aria-expanded", dialog?.open ? "true" : "false");
}

document.addEventListener("turbo:load", () => {
  const dialog = document.getElementById(DIALOG_ID);
  restoreModalState(dialog);
  syncLauncherExpandedState(dialog);
});

// The chat lives in a native modal <dialog>. Using showModal() gives us
// focus containment, an inert workspace, and Escape-to-close without
// hand-rolling a focus trap. The dialog is a Turbo-permanent element, so the
// conversation survives both dismissal and page navigation.
export default class extends Controller {
  static targets = ["dialog", "launcher"];

  connect() {
    this.handleClose = this.handleClose.bind(this);
    this.dialogTarget.addEventListener("close", this.handleClose);
    restoreModalState(this.dialogTarget);
    this.#syncExpandedState();
  }

  disconnect() {
    this.dialogTarget.removeEventListener("close", this.handleClose);
  }

  open(event) {
    event?.preventDefault();

    if (!this.dialogTarget.open) {
      this.dialogTarget.showModal();
    }

    this.#syncExpandedState();
  }

  close() {
    if (this.dialogTarget.open) {
      this.dialogTarget.close();
      this.#syncExpandedState();
    }
  }

  handleClose() {
    this.#syncExpandedState();

    if (!this.dialogTarget.open) {
      this.launcherTarget.focus({ preventScroll: true });
    }
  }

  #syncExpandedState() {
    syncLauncherExpandedState(this.dialogTarget);
  }
}
