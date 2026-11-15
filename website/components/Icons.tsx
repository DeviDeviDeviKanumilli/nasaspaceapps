// One small inline icon set (1.6 px strokes, 16 px box). Used only where an icon carries meaning.
const base = { width: 16, height: 16, viewBox: "0 0 16 16", fill: "none", stroke: "currentColor", strokeWidth: 1.6, strokeLinecap: "round" as const, strokeLinejoin: "round" as const, "aria-hidden": true };
export const IconX = () => (<svg {...base}><path d="M3.5 3.5l9 9M12.5 3.5l-9 9" /></svg>);
export const IconSearch = () => (<svg {...base} width={14} height={14}><circle cx="7" cy="7" r="4.5" /><path d="M10.5 10.5L14 14" /></svg>);
export const IconInfo = () => (<svg {...base} width={14} height={14}><circle cx="8" cy="8" r="6.2" /><path d="M8 7.2v4M8 4.8v.2" /></svg>);
export const IconBack = () => (<svg {...base} width={14} height={14}><path d="M9.5 3L4.5 8l5 5" /></svg>);
export const IconChevron = () => (<svg {...base} width={12} height={12}><path d="M6 3l5 5-5 5" /></svg>);
export const IconPlus = () => (<svg {...base}><path d="M8 3v10M3 8h10" /></svg>);
export const IconMinus = () => (<svg {...base}><path d="M3 8h10" /></svg>);
export const IconGlobe = () => (<svg {...base}><circle cx="8" cy="8" r="6" /><path d="M2 8h12M8 2c2.2 2.2 2.2 9.8 0 12M8 2c-2.2 2.2-2.2 9.8 0 12" strokeWidth={1.2} /></svg>);
export const IconLayers = () => (<svg {...base}><path d="M8 2.5L2 5.8l6 3.3 6-3.3L8 2.5zM2 8.8l6 3.3 6-3.3" /></svg>);
export const IconExport = () => (<svg {...base} width={14} height={14}><path d="M8 2.5v7.5M5 7l3 3 3-3M3 12.5h10" /></svg>);
