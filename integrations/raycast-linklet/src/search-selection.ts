import {
  closeMainWindow,
  getPreferenceValues,
  getSelectedText,
  open,
  showHUD,
  showToast,
  Toast,
} from "@raycast/api";
import { searchRequest } from "./search-request";

export default async function command() {
  let selectedText: string;
  try {
    selectedText = await getSelectedText();
  } catch {
    await showToast({
      style: Toast.Style.Failure,
      title: "Could not read selected text",
      message:
        "Select text in another app and check Raycast’s Accessibility permission.",
    });
    return;
  }

  const request = searchRequest(selectedText);
  if (!request) {
    await showHUD("Select text in another app first");
    return;
  }

  try {
    const { application } = getPreferenceValues<Preferences>();
    await closeMainWindow();
    await open(request, application ?? "Linklet");
  } catch {
    await showToast({
      style: Toast.Style.Failure,
      title: "Could not open Linklet",
      message:
        "Install the latest Linklet and select it in this extension’s settings.",
    });
  }
}
