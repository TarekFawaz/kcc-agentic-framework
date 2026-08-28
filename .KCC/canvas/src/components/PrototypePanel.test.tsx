/**
 * Behavioral tests for the clickable prototype surface (KCC x
 * Superpowers Hybrid Framework Plan 06, Task 4; Design Spec v1.2
 * section 9.6 "Clickable prototype").
 *
 * Written first (strict TDD red phase), against the external behavior
 * contract of :file:`src/components/PrototypePanel.tsx`:
 *
 * * the prototype iframe sandbox is EXACTLY ``allow-forms
 *   allow-scripts`` — forms and scripts work, but same-origin access
 *   (``allow-same-origin``) is never granted, so the embedded
 *   prototype can never read the canvas host document;
 * * the iframe src is the prototype reference from the contract's
 *   Tier-1 invariants (``prototype_ref``), never a client-invented
 *   URL;
 * * with no prototype yet the panel renders an empty state and no
 *   iframe.
 *
 * The component is rendered to static markup with ``react-dom/server``,
 * so the assertions inspect the real sandbox attribute output.
 */
import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";

import { PROTOTYPE_SANDBOX, PrototypePanel } from "./PrototypePanel";

const PROTOTYPE_URL = "https://preview.example.test/prototype/run-042/";

function iframeTag(html: string): string {
  return /<iframe[^>]*>/.exec(html)?.[0] ?? "";
}

describe("PROTOTYPE_SANDBOX", () => {
  it("is exactly allow-forms allow-scripts with no same-origin grant", () => {
    expect(PROTOTYPE_SANDBOX).toBe("allow-forms allow-scripts");
    expect(PROTOTYPE_SANDBOX.split(" ")).toHaveLength(2);
    expect(PROTOTYPE_SANDBOX).not.toContain("allow-same-origin");
  });
});

describe("PrototypePanel iframe sandbox", () => {
  it("renders the sandbox attribute exactly as configured", () => {
    const html = renderToStaticMarkup(<PrototypePanel prototypeRef={PROTOTYPE_URL} />);
    const iframe = iframeTag(html);
    expect(iframe).toContain('sandbox="allow-forms allow-scripts"');
  });

  it("never grants allow-same-origin to the embedded prototype", () => {
    const html = renderToStaticMarkup(<PrototypePanel prototypeRef={PROTOTYPE_URL} />);
    expect(html).not.toContain("allow-same-origin");
    expect(iframeTag(html).split(" ")).not.toContain("allow-same-origin");
  });

  it("points the iframe at the prototype reference from the contract", () => {
    const html = renderToStaticMarkup(<PrototypePanel prototypeRef={PROTOTYPE_URL} />);
    expect(iframeTag(html)).toContain(`src="${PROTOTYPE_URL}"`);
  });

  it("gives the iframe an accessible title", () => {
    const html = renderToStaticMarkup(<PrototypePanel prototypeRef={PROTOTYPE_URL} />);
    expect(iframeTag(html)).toContain("title=");
  });
});

describe("PrototypePanel empty state", () => {
  it("renders an empty state and no iframe when no prototype exists yet", () => {
    const html = renderToStaticMarkup(<PrototypePanel prototypeRef={null} />);
    expect(html).toContain("prototype-panel__empty");
    expect(html).not.toContain("<iframe");
  });
});
