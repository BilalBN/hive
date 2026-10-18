import {
  Activity,
  AudioWaveform,
  DatabaseBackup,
  Disc3,
  LayoutGrid,
  Library,
  type LucideIcon,
  MonitorSmartphone,
  ScrollText,
  Settings,
  Upload,
  UserCheck,
  UserPlus,
  Users,
} from "lucide-react";

export type Milestone = "M0" | "M1" | "M2" | "M3" | "M4";

export interface Section {
  path: string;
  label: string;
  icon: LucideIcon;
  /** The milestone that builds this page. */
  milestone: Milestone;
  /** One line describing the page, shown under its title. */
  summary: string;
}

/** Hive Admin's pages, grouped as in the navigation. Settings sits at the foot. */
export const sectionGroups: Section[][] = [
  [
    { path: "/", label: "Overview", icon: LayoutGrid, milestone: "M0", summary: "How home is doing." },
    { path: "/requests", label: "Requests", icon: UserCheck, milestone: "M2", summary: "People and devices waiting to be let in, and songs the family asked for." },
    { path: "/people", label: "People", icon: Users, milestone: "M2", summary: "Everyone with access, their devices and status." },
    { path: "/devices", label: "Devices", icon: MonitorSmartphone, milestone: "M2", summary: "Every phone and computer across the family." },
    { path: "/invite", label: "Invite", icon: UserPlus, milestone: "M2", summary: "Invite someone with a private-network link and a Hive code." },
  ],
  [
    { path: "/library", label: "Library", icon: Library, milestone: "M1", summary: "Music folders, the import queue and files that need attention." },
    { path: "/albums", label: "Albums", icon: Disc3, milestone: "M1", summary: "Check and correct what Hive knows about each album." },
    { path: "/upload", label: "Upload", icon: Upload, milestone: "M1", summary: "Add music from this computer." },
    { path: "/recognition", label: "Recognition", icon: AudioWaveform, milestone: "M3", summary: "Fingerprint coverage and how Listen is doing." },
  ],
  [
    { path: "/activity", label: "Activity", icon: Activity, milestone: "M2", summary: "Every admin action, for the record." },
    { path: "/backups", label: "Backups", icon: DatabaseBackup, milestone: "M4", summary: "Schedule, destination and restores." },
    { path: "/logs", label: "Logs", icon: ScrollText, milestone: "M4", summary: "What the server has been doing." },
  ],
];

export const settingsSection: Section = {
  path: "/settings",
  label: "Settings",
  icon: Settings,
  milestone: "M2",
  summary: "Names, limits, email and updates.",
};

export const allSections: Section[] = [...sectionGroups.flat(), settingsSection];
