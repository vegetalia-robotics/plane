import { TIssue } from "./issues/issue";

export type TIssueSyncEvent = {
  type: "issues:sync";
  data: TIssue[];
};

export type TIssueRemoveEvent = {
  type: "issues:remove";
  data: string[];
};

export type TIssueBroadcastEvent = {
  data: (TIssueSyncEvent | TIssueRemoveEvent) & { workspaceSlug: string; projectId: string };
};
