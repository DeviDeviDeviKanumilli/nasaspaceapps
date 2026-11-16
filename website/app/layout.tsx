import type { Metadata, Viewport } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "TERRALYTX — Earth analogs for Moon and Mars reference sites",
  description: "Interactive globe of computed Earth analog records for lunar and Martian reference sites, with measurements, sources and coverage limits.",
};
export const viewport: Viewport = { width: "device-width", initialScale: 1, themeColor: "#02050A" };

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
