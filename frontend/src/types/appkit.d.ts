import type { DetailedHTMLProps, HTMLAttributes } from "react";

declare global {
  namespace JSX {
    interface IntrinsicElements {
      "appkit-button": DetailedHTMLProps<HTMLAttributes<HTMLElement>, HTMLElement>;
      "appkit-network-button": DetailedHTMLProps<HTMLAttributes<HTMLElement>, HTMLElement>;
    }
  }
}

export {};
