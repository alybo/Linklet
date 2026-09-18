/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {
  /** Linklet Application - Choose the installed Linklet app. The search engine is configured in Linklet → Settings → Search. */
  "application"?: import("@raycast/api").Application
}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `search-selection` command */
  export type SearchSelection = ExtensionPreferences & {}
}

declare namespace Arguments {
  /** Arguments passed to the `search-selection` command */
  export type SearchSelection = {}
}

