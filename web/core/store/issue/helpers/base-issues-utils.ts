import cloneDeep from "lodash/cloneDeep";
import isEmpty from "lodash/isEmpty";
import uniq from "lodash/uniq";
// plane imports
import { ALL_ISSUES, EIssuesStoreType } from "@plane/constants";
import { IIssueDisplayFilterOptions, IIssueFilterOptions, TIssue } from "@plane/types";
// constants
import { FILTER_TO_ISSUE_MAP } from "@/constants/issue";
// helpers
import { checkDateCriteria, parseDateFilter } from "@/helpers/date-time.helper";
// store
import { store } from "@/lib/store-context";
import { EIssueGroupedAction } from "./base-issues.store";

/**
 * returns,
 * A compound key, if both groupId & subGroupId are defined
 * groupId, only if groupId is defined
 * ALL_ISSUES, if both groupId & subGroupId are not defined
 * @param groupId
 * @param subGroupId
 * @returns
 */
export const getGroupKey = (groupId?: string, subGroupId?: string) => {
  if (groupId && subGroupId && subGroupId !== "null") return `${groupId}_${subGroupId}`;

  if (groupId) return groupId;

  return ALL_ISSUES;
};

/**
 * This method returns the issue key actions for based on the difference in issue properties of grouped values
 * @param addArray Array of groupIds at which the issue needs to be added
 * @param deleteArray Array of groupIds at which the issue needs to be deleted
 * @returns an array of objects that contains the issue Path at which it needs to be updated and the action that needs to be performed at the path as well
 */
export const getGroupIssueKeyActions = (
  addArray: string[],
  deleteArray: string[]
): { path: string[]; action: EIssueGroupedAction }[] => {
  const issueKeyActions = [];

  // Add all the groupIds as IssueKey and action as Add
  for (const addKey of addArray) {
    issueKeyActions.push({ path: [addKey], action: EIssueGroupedAction.ADD });
  }

  // Add all the groupIds as IssueKey and action as Delete
  for (const deleteKey of deleteArray) {
    issueKeyActions.push({ path: [deleteKey], action: EIssueGroupedAction.DELETE });
  }

  return issueKeyActions;
};

/**
 * This method returns the issue key actions for based on the difference in issue properties of grouped and subGrouped values
 * @param groupActionsArray Addition and Deletion arrays of groupIds at which the issue needs to be added and deleted
 * @param subGroupActionsArray Addition and Deletion arrays of subGroupIds at which the issue needs to be added and deleted
 * @param previousIssueGroupProperties previous value of the issue property that on which grouping is dependent on
 * @param currentIssueGroupProperties current value of the issue property that on which grouping is dependent on
 * @param previousIssueSubGroupProperties previous value of the issue property that on which subGrouping is dependent on
 * @param currentIssueSubGroupProperties current value of the issue property that on which subGrouping is dependent on
 * @returns an array of objects that contains the issue Path at which it needs to be updated and the action that needs to be performed at the path as well
 */
export const getSubGroupIssueKeyActions = (
  groupActionsArray: {
    [EIssueGroupedAction.ADD]: string[];
    [EIssueGroupedAction.DELETE]: string[];
  },
  subGroupActionsArray: {
    [EIssueGroupedAction.ADD]: string[];
    [EIssueGroupedAction.DELETE]: string[];
  },
  previousIssueGroupProperties: string[],
  currentIssueGroupProperties: string[],
  previousIssueSubGroupProperties: string[],
  currentIssueSubGroupProperties: string[]
): { path: string[]; action: EIssueGroupedAction }[] => {
  const issueKeyActions: { [key: string]: { path: string[]; action: EIssueGroupedAction } } = {};

  // For every groupId path for issue Id List, that needs to be added,
  // It needs to be added at all the current Issue Properties that on which subGrouping depends on
  for (const addKey of groupActionsArray[EIssueGroupedAction.ADD]) {
    for (const subGroupProperty of currentIssueSubGroupProperties) {
      issueKeyActions[getGroupKey(addKey, subGroupProperty)] = {
        path: [addKey, subGroupProperty],
        action: EIssueGroupedAction.ADD,
      };
    }
  }

  // For every groupId path for issue Id List, that needs to be deleted,
  // It needs to be deleted at all the previous Issue Properties that on which subGrouping depends on
  for (const deleteKey of groupActionsArray[EIssueGroupedAction.DELETE]) {
    for (const subGroupProperty of previousIssueSubGroupProperties) {
      issueKeyActions[getGroupKey(deleteKey, subGroupProperty)] = {
        path: [deleteKey, subGroupProperty],
        action: EIssueGroupedAction.DELETE,
      };
    }
  }

  // For every subGroupId path for issue Id List, that needs to be added,
  // It needs to be added at all the current Issue Properties that on which grouping depends on
  for (const addKey of subGroupActionsArray[EIssueGroupedAction.ADD]) {
    for (const groupProperty of currentIssueGroupProperties) {
      issueKeyActions[getGroupKey(groupProperty, addKey)] = {
        path: [groupProperty, addKey],
        action: EIssueGroupedAction.ADD,
      };
    }
  }

  // For every subGroupId path for issue Id List, that needs to be deleted,
  // It needs to be deleted at all the previous Issue Properties that on which grouping depends on
  for (const deleteKey of subGroupActionsArray[EIssueGroupedAction.DELETE]) {
    for (const groupProperty of previousIssueGroupProperties) {
      issueKeyActions[getGroupKey(groupProperty, deleteKey)] = {
        path: [groupProperty, deleteKey],
        action: EIssueGroupedAction.DELETE,
      };
    }
  }

  return Object.values(issueKeyActions);
};

/**
 * This Method is used to get the difference between two arrays
 * @param current
 * @param previous
 * @param action
 * @returns returns two arrays, ADD and DELETE.
 *           Whatever is newly added to current is added to ADD array
 *           Whatever is removed from previous is added to DELETE array
 */
export const getDifference = (
  current: string[],
  previous: string[],
  action?: EIssueGroupedAction.ADD | EIssueGroupedAction.DELETE
): { [EIssueGroupedAction.ADD]: string[]; [EIssueGroupedAction.DELETE]: string[] } => {
  const ADD = [];
  const DELETE = [];

  // For all the current issues values that are not in the previous array, Add them to the ADD array
  for (const currentValue of current) {
    if (previous.includes(currentValue)) continue;
    ADD.push(currentValue);
  }

  // For all the previous issues values that are not in the current array, Add them to the ADD array
  for (const previousValue of previous) {
    if (current.includes(previousValue)) continue;
    DELETE.push(previousValue);
  }

  // if there are no action provided, return the arrays
  if (!action) return { [EIssueGroupedAction.ADD]: ADD, [EIssueGroupedAction.DELETE]: DELETE };

  // If there is an action provided, return the values of both arrays under that array
  if (action === EIssueGroupedAction.ADD)
    return { [EIssueGroupedAction.ADD]: uniq([...ADD]), [EIssueGroupedAction.DELETE]: [] };
  else return { [EIssueGroupedAction.DELETE]: uniq([...DELETE]), [EIssueGroupedAction.ADD]: [] };
};

/**
 * This Method is mainly used to filter out empty values in the beginning
 * @param key key of the value that is to be checked if empty
 * @param object any object in which the key's value is to be checked
 * @returns 1 if empty, 0 if not empty
 */
export const getSortOrderToFilterEmptyValues = (key: string, object: any) => {
  const value = object?.[key];

  if (typeof value !== "number" && isEmpty(value)) return 1;

  return 0;
};

// get IssueIds from Issue data List
export const getIssueIds = (issues: TIssue[]) => issues.map((issue) => issue?.id);

/**
 * Helper method to get the active issue store type
 * @returns The active issue store type
 */
export const getActiveIssueStoreType = () => {
  const { globalViewId, viewId, projectId, cycleId, moduleId, userId, epicId, teamId } = store.router;

  // Check the router store to determine the active issue store
  if (globalViewId) return EIssuesStoreType.GLOBAL;

  if (userId) return EIssuesStoreType.PROFILE;

  if (teamId && viewId) return EIssuesStoreType.TEAM_VIEW;

  if (teamId) return EIssuesStoreType.TEAM;

  if (projectId && viewId) return EIssuesStoreType.PROJECT_VIEW;

  if (cycleId) return EIssuesStoreType.CYCLE;

  if (moduleId) return EIssuesStoreType.MODULE;

  if (epicId) return EIssuesStoreType.EPIC;

  if (projectId) return EIssuesStoreType.PROJECT;
};

/**
 * Helper method to determine if the current issue store is active
 * @param currentStoreType - The current issue store type
 * @returns true if the current issue store is active, false otherwise
 */
export const isCurrentIssueStoreActive = (currentStoreType: EIssuesStoreType) => {
  const activeStoreType: EIssuesStoreType | undefined = getActiveIssueStoreType();
  return currentStoreType === activeStoreType;
};

/**
 * Helper method to get previous issues state
 * @param issues - The array of issues to get the previous state for.
 * @returns The previous state of the issues.
 */
export const getPreviousIssuesState = (issues: TIssue[]) => {
  const issueIds = issues.map((issue) => issue.id);
  const issuesPreviousState: Record<string, TIssue> = {};
  issueIds.forEach((issueId) => {
    if (store.issue.issues.issuesMap[issueId]) {
      issuesPreviousState[issueId] = cloneDeep(store.issue.issues.issuesMap[issueId]);
    }
  });
  return issuesPreviousState;
};

/**
 * Checks if an issue meets the date filter criteria
 * @param issue The issue to check
 * @param filterKey The date field to check ('start_date' or 'target_date')
 * @param dateFilters Array of date filter strings
 * @returns boolean indicating if the issue meets the date criteria
 */
export const checkIssueDateFilter = (
  issue: TIssue,
  filterKey: "start_date" | "target_date",
  dateFilters: string[]
): boolean => {
  if (!dateFilters || dateFilters.length === 0) return true;

  const issueDate = issue[filterKey];
  if (!issueDate) return false;

  // Issue should match all the date filters (AND operation)
  return dateFilters.every((filterValue) => {
    const { type, date } = parseDateFilter(filterValue);
    return checkDateCriteria(new Date(issueDate), date, type);
  });
};

/**
 * Filters the given issues based on the provided filters and display filters.
 * @param issues - The array of issues to be filtered.
 * @param filters - The filters to be applied to the issues.
 * @param displayFilters - The display filters to be applied to the issues.
 * @returns The filtered array of issues.
 */
export const getFilteredIssues = (
  issues: TIssue[],
  filters: IIssueFilterOptions | undefined,
  displayFilters: IIssueDisplayFilterOptions | undefined
): TIssue[] => {
  if (!filters) return issues;
  // Get all active filters
  const activeFilters = Object.entries(filters).filter(([, value]) => value && value.length > 0);

  return issues.filter((issue) => {
    // Handle sub-issue display filter
    if (issue.parent_id !== null && displayFilters?.sub_issue === false) {
      return false;
    }
    // If no active filters, return all issues
    if (activeFilters.length === 0) {
      return true;
    }
    // Check all filter conditions (AND operation between different filters)
    return activeFilters.every(([filterKey, filterValues]) => {
      // Handle date filters separately
      if (filterKey === "start_date" || filterKey === "target_date") {
        return checkIssueDateFilter(issue, filterKey as "start_date" | "target_date", filterValues as string[]);
      }
      // Handle regular filters
      const issueKey = FILTER_TO_ISSUE_MAP[filterKey as keyof IIssueFilterOptions];
      if (!issueKey) return true; // Skip if no mapping exists
      const issueValue = issue[issueKey as keyof TIssue];
      // Handle array-based properties vs single value properties
      if (Array.isArray(issueValue)) {
        return filterValues!.some((filterValue: any) => issueValue.includes(filterValue));
      } else {
        return filterValues!.includes(issueValue as string);
      }
    });
  });
};
