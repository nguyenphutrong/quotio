#!/usr/bin/env bun

import "./cli/commands/quota.ts";
import "./cli/commands/auth.ts";
import "./cli/commands/proxy.ts";
import "./cli/commands/agent.ts";
import "./cli/commands/config.ts";
import "./cli/commands/daemon.ts";
import "./cli/commands/fallback.ts";

import { run } from "./cli/index.ts";

run();
