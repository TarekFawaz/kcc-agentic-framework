/**
 * Clickable prototype surface for the autobuild canvas.
 *
 * KCC x Superpowers Hybrid Framework Plan 06, Task 4 (Design Spec v1.2
 * section 9.6 "Clickable prototype"): the validated prototype is a
 * pre-lock artifact shown as an embedded frame.  The prototype is not
 * production implementation and must never gain access to the canvas
 * document, so the iframe sandbox is EXACTLY ``allow-forms
 * allow-scripts`` — forms and scripts work, same-origin access is
 * never granted.
 *
 * The frame src is the prototype reference from the contract's Tier-1
 * invariants (``Tier1Invariants.prototype_ref``); with no reference
 * yet the panel renders an empty state and no iframe.
 */

/** Sandbox of the embedded prototype: forms + scripts, never same-origin. */
export const PROTOTYPE_SANDBOX = "allow-forms allow-scripts";

export function PrototypePanel({ prototypeRef }: { prototypeRef: string | null }) {
  return (
    <section className="prototype-panel" aria-label="Clickable prototype">
      <h2>Prototype</h2>
      {prototypeRef === null ? (
        <p className="prototype-panel__empty">
          No prototype yet — the clickable prototype appears once prototype
          review produces it.
        </p>
      ) : (
        <iframe
          className="prototype-panel__frame"
          src={prototypeRef}
          title="Autobuild prototype preview"
          sandbox={PROTOTYPE_SANDBOX}
        />
      )}
    </section>
  );
}
