// What each read call recorded, stored and replayed before capture claims moved onto the source adapters.
export const RECORDED = {
  "Linear get_issue": {
    "noted": {
      "addresses": [
        "https://linear.app/acme/issue/WEB-2757"
      ],
      "learned": true
    },
    "stored": {
      "https://linear.app/acme/issue/WEB-2757": {
        "address": "https://linear.app/acme/issue/WEB-2757",
        "kind": "linear-issue",
        "source": "mcp",
        "server": "claude_ai_Linear",
        "tool": "get_issue",
        "args": {
          "id": "WEB-2757"
        },
        "result": "{\"id\":\"WEB-2757\",\"uuid\":\"cdc293c3-0000-0000-0000-000000000000\",\"title\":\"Remove Logo\",\"description\":\"The logo should go.\",\"priority\":{\"value\":3,\"name\":\"Medium\"},\"url\":\"https://linear.app/acme/issue/WEB-2757/remove-logo\",\"createdAt\":\"2026-10-01T09:00:00.000Z\",\"updatedAt\":\"2026-10-05T12:30:00.000Z\",\"completedAt\":null,\"canceledAt\":null,\"status\":\"In Progress\",\"statusType\":\"started\",\"assignee\":null,\"project\":\"Brand refresh\",\"projectId\":\"p-1\",\"parentId\":\"WEB-2700\",\"team\":\"Web\",\"teamId\":\"t-1\"}",
        "at": 7000
      }
    }
  },
  "Linear get_project": {
    "noted": {
      "addresses": [
        "https://linear.app/acme/project/brand-refresh-1a2b3c4d5e6f"
      ],
      "learned": false
    },
    "stored": {
      "https://linear.app/acme/project/brand-refresh-1a2b3c4d5e6f": {
        "address": "https://linear.app/acme/project/brand-refresh-1a2b3c4d5e6f",
        "kind": "linear-project",
        "source": "mcp",
        "server": "claude_ai_Linear",
        "tool": "get_project",
        "args": {
          "query": "Brand refresh"
        },
        "result": "{\"id\":\"P-WEB-610\",\"name\":\"Brand refresh\",\"summary\":\"\",\"description\":null,\"url\":\"https://linear.app/acme/project/brand-refresh-1a2b3c4d5e6f\",\"startDate\":\"2026-09-01\",\"targetDate\":\"2026-12-01\",\"priority\":{\"value\":0,\"name\":\"No priority\"},\"labels\":[],\"lead\":{\"id\":\"u-1\",\"name\":\"Ada Lovelace\"},\"leadTeam\":{\"id\":\"t-1\",\"name\":\"Web\",\"key\":\"WEB\"},\"status\":{\"id\":\"s-1\",\"name\":\"Completed\",\"type\":\"completed\"},\"teams\":[{\"id\":\"t-1\",\"name\":\"Web\",\"key\":\"WEB\"}]}",
        "at": 7000
      }
    }
  },
  "Linear get_issue by bare key once the team is known": {
    "noted": {
      "addresses": [
        "https://linear.app/acme/issue/WEB-12"
      ],
      "learned": false
    },
    "stored": {
      "https://linear.app/acme/issue/WEB-12": {
        "address": "https://linear.app/acme/issue/WEB-12",
        "kind": "linear-issue",
        "source": "mcp",
        "server": "linear",
        "tool": "get_issue",
        "args": {
          "id": "web-12"
        },
        "result": "{\"title\":\"no url\"}",
        "at": 7000
      }
    }
  },
  "Linear get_issue whose result names another issue": {
    "noted": {
      "addresses": [
        "https://linear.app/acme/issue/WEB-2757"
      ],
      "learned": false
    },
    "stored": {
      "https://linear.app/acme/issue/WEB-2757": {
        "address": "https://linear.app/acme/issue/WEB-2757",
        "kind": "linear-issue",
        "source": "mcp",
        "server": "claude_ai_Linear",
        "tool": "get_issue",
        "args": {
          "id": "WEB-2757"
        },
        "result": "{\"id\":\"WEB-2757\",\"uuid\":\"cdc293c3-0000-0000-0000-000000000000\",\"title\":\"Remove Logo\",\"description\":\"The logo should go.\",\"priority\":{\"value\":3,\"name\":\"Medium\"},\"url\":\"https://linear.app/acme/issue/WEB-2757/remove-logo\",\"createdAt\":\"2026-10-01T09:00:00.000Z\",\"updatedAt\":\"2026-10-05T12:30:00.000Z\",\"completedAt\":null,\"canceledAt\":null,\"status\":\"In Progress\",\"statusType\":\"started\",\"assignee\":null,\"project\":\"Brand refresh\",\"projectId\":\"p-1\",\"parentId\":\"WEB-2700\",\"team\":\"Web\",\"teamId\":\"t-1\"}",
        "at": 7000
      },
      "https://linear.app/acme/issue/WEB-13": null
    }
  },
  "Linear server issue_read": {
    "noted": {
      "addresses": [
        "https://linear.app/acme/issue/WEB-14"
      ],
      "learned": false
    },
    "stored": {
      "https://linear.app/acme/issue/WEB-14": {
        "address": "https://linear.app/acme/issue/WEB-14",
        "kind": "linear-issue",
        "source": "mcp",
        "server": "claude_ai_Linear",
        "tool": "issue_read",
        "args": {
          "id": "WEB-14"
        },
        "result": "{}",
        "at": 7000
      }
    }
  },
  "Linear list_issues": {
    "noted": {
      "addresses": [
        "https://linear.app/acme/issue/WEB-15"
      ],
      "learned": false
    },
    "stored": {
      "https://linear.app/acme/issue/WEB-15": null
    }
  },
  "GitHub MCP pull_request_read get": {
    "noted": {
      "addresses": [
        "https://github.com/acme/widgets/pull/42"
      ],
      "learned": false
    },
    "stored": {
      "https://github.com/acme/widgets/pull/42": {
        "address": "https://github.com/acme/widgets/pull/42",
        "kind": "gh-pr",
        "source": "mcp",
        "server": "claude_ai_Github",
        "tool": "pull_request_read",
        "args": {
          "method": "get",
          "owner": "acme",
          "repo": "widgets",
          "pullNumber": 42
        },
        "result": "{\"number\":42,\"title\":\"Teach the parser trailing commas\",\"state\":\"open\",\"draft\":false,\"user\":{\"login\":\"octo\"},\"body\":\"Fixes the trailing comma.\",\"created_at\":\"2026-09-01T10:00:00Z\",\"updated_at\":\"2026-09-03T12:00:00Z\",\"merged_at\":null,\"additions\":120,\"deletions\":8,\"changed_files\":4,\"html_url\":\"https://github.com/acme/widgets/pull/42\"}",
        "at": 7000
      }
    }
  },
  "GitHub MCP issue_read get": {
    "noted": {
      "addresses": [
        "https://github.com/acme/widgets/issues/7"
      ],
      "learned": false
    },
    "stored": {
      "https://github.com/acme/widgets/issues/7": {
        "address": "https://github.com/acme/widgets/issues/7",
        "kind": "gh-issue",
        "source": "mcp",
        "server": "claude_ai_Github",
        "tool": "issue_read",
        "args": {
          "method": "get",
          "owner": "acme",
          "repo": "widgets",
          "issue_number": 7
        },
        "result": "{\"number\":7}",
        "at": 7000
      }
    }
  },
  "GitHub MCP get_pull_request": {
    "noted": {
      "addresses": [
        "https://github.com/acme/widgets/pull/43"
      ],
      "learned": false
    },
    "stored": {
      "https://github.com/acme/widgets/pull/43": {
        "address": "https://github.com/acme/widgets/pull/43",
        "kind": "gh-pr",
        "source": "mcp",
        "server": "github",
        "tool": "get_pull_request",
        "args": {
          "owner": "acme",
          "repo": "widgets",
          "pull_number": 43
        },
        "result": "{}",
        "at": 7000
      }
    }
  },
  "GitHub MCP get_issue on a pull number": {
    "noted": {
      "addresses": [
        "https://github.com/acme/widgets/pull/44"
      ],
      "learned": false
    },
    "stored": {
      "https://github.com/acme/widgets/pull/44": {
        "address": "https://github.com/acme/widgets/pull/44",
        "kind": "gh-pr",
        "source": "mcp",
        "server": "github",
        "tool": "get_pull_request_status",
        "args": {
          "owner": "acme",
          "repo": "widgets",
          "issueNumber": 44
        },
        "result": "{}",
        "at": 7000
      }
    }
  },
  "GitHub MCP sub-method read": {
    "noted": {
      "addresses": [
        "https://github.com/acme/widgets/pull/45"
      ],
      "learned": false
    },
    "stored": {
      "https://github.com/acme/widgets/pull/45": null
    }
  },
  "GitHub server slack_read_ tool": {
    "noted": {
      "addresses": [],
      "learned": false
    },
    "stored": {}
  },
  "Slack server get_ tool": {
    "noted": {
      "addresses": [
        "https://github.com/acme/widgets/pull/47"
      ],
      "learned": false
    },
    "stored": {
      "https://github.com/acme/widgets/pull/47": {
        "address": "https://github.com/acme/widgets/pull/47",
        "kind": "gh-pr",
        "source": "mcp",
        "server": "plugin_slack_slack",
        "tool": "get_item",
        "args": {
          "owner": "acme",
          "repo": "widgets",
          "pullNumber": 47
        },
        "result": "{}",
        "at": 7000
      }
    }
  },
  "Slack read_thread": {
    "noted": {
      "addresses": [],
      "learned": false
    },
    "stored": {}
  },
  "unknown server get_ tool": {
    "noted": {
      "addresses": [],
      "learned": false
    },
    "stored": {}
  },
  "gh pr view": {
    "noted": {
      "addresses": [
        "https://github.com/acme/widgets/pull/49"
      ],
      "learned": false
    },
    "stored": {
      "https://github.com/acme/widgets/pull/49": {
        "address": "https://github.com/acme/widgets/pull/49",
        "kind": "gh-pr",
        "source": "bash",
        "tool": "Bash",
        "args": {
          "command": "gh pr view 49 --repo acme/widgets --json title,state"
        },
        "result": "{\"title\":\"Fix\"}",
        "at": 7000
      }
    }
  },
  "gh issue view": {
    "noted": {
      "addresses": [
        "https://github.com/acme/widgets/issues/50"
      ],
      "learned": false
    },
    "stored": {
      "https://github.com/acme/widgets/issues/50": {
        "address": "https://github.com/acme/widgets/issues/50",
        "kind": "gh-issue",
        "source": "bash",
        "tool": "Bash",
        "args": {
          "command": "gh issue view 50 -R acme/widgets --json title"
        },
        "result": "{\"title\":\"Bug\"}",
        "at": 7000
      }
    }
  },
  "gh api issue": {
    "noted": {
      "addresses": [
        "https://github.com/acme/widgets/issues/51"
      ],
      "learned": false
    },
    "stored": {
      "https://github.com/acme/widgets/issues/51": {
        "address": "https://github.com/acme/widgets/issues/51",
        "kind": "gh-issue",
        "source": "bash",
        "tool": "Bash",
        "args": {
          "command": "gh api repos/acme/widgets/issues/51"
        },
        "result": "{\"number\":51}",
        "at": 7000
      }
    }
  },
  "gh pr list": {
    "noted": {
      "addresses": [
        "https://github.com/acme/widgets/pull/52"
      ],
      "learned": false
    },
    "stored": {
      "https://github.com/acme/widgets/pull/52": null
    }
  },
  "WebFetch": {
    "noted": {
      "addresses": [
        "https://example.com/page"
      ],
      "learned": false
    },
    "stored": {
      "https://example.com/page": {
        "address": "https://example.com/page",
        "kind": "web",
        "source": "webfetch",
        "tool": "WebFetch",
        "args": {
          "url": "https://example.com/page#top",
          "prompt": "x"
        },
        "result": "# Page",
        "at": 7000
      }
    }
  },
  "an errored read": {
    "noted": {
      "addresses": [],
      "learned": false
    },
    "stored": {}
  },
  "a denied read": {
    "noted": {
      "addresses": [],
      "learned": false
    },
    "stored": {}
  }
} as const

export const REPLAYED = {
  "https://linear.app/acme/issue/WEB-2757": {
    "entry": {
      "address": "https://linear.app/acme/issue/WEB-2757",
      "kind": "linear-issue",
      "source": "mcp",
      "server": "claude_ai_Linear",
      "tool": "get_issue",
      "args": {
        "id": "WEB-2757"
      },
      "result": "fresh get_issue",
      "at": 9000
    },
    "calls": [
      {
        "server": "claude_ai_Linear",
        "tool": "get_issue",
        "args": {
          "id": "WEB-2757"
        }
      }
    ]
  },
  "https://linear.app/acme/project/brand-refresh-1a2b3c4d5e6f": {
    "entry": {
      "address": "https://linear.app/acme/project/brand-refresh-1a2b3c4d5e6f",
      "kind": "linear-project",
      "source": "mcp",
      "server": "claude_ai_Linear",
      "tool": "get_project",
      "args": {
        "query": "Brand refresh"
      },
      "result": "fresh get_project",
      "at": 9000
    },
    "calls": [
      {
        "server": "claude_ai_Linear",
        "tool": "get_project",
        "args": {
          "query": "Brand refresh"
        }
      }
    ]
  },
  "https://linear.app/acme/issue/WEB-12": {
    "entry": {
      "address": "https://linear.app/acme/issue/WEB-12",
      "kind": "linear-issue",
      "source": "mcp",
      "server": "linear",
      "tool": "get_issue",
      "args": {
        "id": "web-12"
      },
      "result": "fresh get_issue",
      "at": 9000
    },
    "calls": [
      {
        "server": "linear",
        "tool": "get_issue",
        "args": {
          "id": "web-12"
        }
      }
    ]
  },
  "https://linear.app/acme/issue/WEB-13": {
    "entry": null,
    "calls": []
  },
  "https://linear.app/acme/issue/WEB-14": {
    "entry": {
      "address": "https://linear.app/acme/issue/WEB-14",
      "kind": "linear-issue",
      "source": "mcp",
      "server": "claude_ai_Linear",
      "tool": "issue_read",
      "args": {
        "id": "WEB-14"
      },
      "result": "fresh issue_read",
      "at": 9000
    },
    "calls": [
      {
        "server": "claude_ai_Linear",
        "tool": "issue_read",
        "args": {
          "id": "WEB-14"
        }
      }
    ]
  },
  "https://linear.app/acme/issue/WEB-15": {
    "entry": null,
    "calls": []
  },
  "https://github.com/acme/widgets/pull/42": {
    "entry": {
      "address": "https://github.com/acme/widgets/pull/42",
      "kind": "gh-pr",
      "source": "mcp",
      "server": "claude_ai_Github",
      "tool": "pull_request_read",
      "args": {
        "method": "get",
        "owner": "acme",
        "repo": "widgets",
        "pullNumber": 42
      },
      "result": "fresh pull_request_read",
      "at": 9000
    },
    "calls": [
      {
        "server": "claude_ai_Github",
        "tool": "pull_request_read",
        "args": {
          "method": "get",
          "owner": "acme",
          "repo": "widgets",
          "pullNumber": 42
        }
      }
    ]
  },
  "https://github.com/acme/widgets/issues/7": {
    "entry": {
      "address": "https://github.com/acme/widgets/issues/7",
      "kind": "gh-issue",
      "source": "mcp",
      "server": "claude_ai_Github",
      "tool": "issue_read",
      "args": {
        "method": "get",
        "owner": "acme",
        "repo": "widgets",
        "issue_number": 7
      },
      "result": "fresh issue_read",
      "at": 9000
    },
    "calls": [
      {
        "server": "claude_ai_Github",
        "tool": "issue_read",
        "args": {
          "method": "get",
          "owner": "acme",
          "repo": "widgets",
          "issue_number": 7
        }
      }
    ]
  },
  "https://github.com/acme/widgets/pull/43": {
    "entry": {
      "address": "https://github.com/acme/widgets/pull/43",
      "kind": "gh-pr",
      "source": "mcp",
      "server": "github",
      "tool": "get_pull_request",
      "args": {
        "owner": "acme",
        "repo": "widgets",
        "pull_number": 43
      },
      "result": "fresh get_pull_request",
      "at": 9000
    },
    "calls": [
      {
        "server": "github",
        "tool": "get_pull_request",
        "args": {
          "owner": "acme",
          "repo": "widgets",
          "pull_number": 43
        }
      }
    ]
  },
  "https://github.com/acme/widgets/pull/44": {
    "entry": {
      "address": "https://github.com/acme/widgets/pull/44",
      "kind": "gh-pr",
      "source": "mcp",
      "server": "github",
      "tool": "get_pull_request_status",
      "args": {
        "owner": "acme",
        "repo": "widgets",
        "issueNumber": 44
      },
      "result": "fresh get_pull_request_status",
      "at": 9000
    },
    "calls": [
      {
        "server": "github",
        "tool": "get_pull_request_status",
        "args": {
          "owner": "acme",
          "repo": "widgets",
          "issueNumber": 44
        }
      }
    ]
  },
  "https://github.com/acme/widgets/pull/45": {
    "entry": null,
    "calls": []
  },
  "https://github.com/acme/widgets/pull/47": {
    "entry": {
      "address": "https://github.com/acme/widgets/pull/47",
      "kind": "gh-pr",
      "source": "mcp",
      "server": "plugin_slack_slack",
      "tool": "get_item",
      "args": {
        "owner": "acme",
        "repo": "widgets",
        "pullNumber": 47
      },
      "result": "fresh get_item",
      "at": 9000
    },
    "calls": [
      {
        "server": "plugin_slack_slack",
        "tool": "get_item",
        "args": {
          "owner": "acme",
          "repo": "widgets",
          "pullNumber": 47
        }
      }
    ]
  },
  "https://github.com/acme/widgets/pull/49": {
    "entry": null,
    "calls": []
  },
  "https://github.com/acme/widgets/issues/50": {
    "entry": null,
    "calls": []
  },
  "https://github.com/acme/widgets/issues/51": {
    "entry": null,
    "calls": []
  },
  "https://github.com/acme/widgets/pull/52": {
    "entry": null,
    "calls": []
  },
  "https://example.com/page": {
    "entry": null,
    "calls": []
  }
} as const
