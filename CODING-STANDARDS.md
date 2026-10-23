# Coding Standards

This document defines the common development standards and conventions for projects maintained by HungLo2020.

These standards apply to all projects unless a project has a documented reason to deviate from them.

## 1. Agent Instructions

Every repository must contain an `AGENTS.md` file.

- The project's `README.md` must contain a dedicated `## AGENTS` section with agent instructions.
- `AGENTS.md` should be a symbolic link to `README.md`, making the README the single source of truth for agent instructions.
- Agent instructions must be kept accurate and maintained alongside the project.

## 2. Centralized Coding Standards

Every project's README must include a link to this document:

[CODING-STANDARDS.md](https://github.com/HungLo2020/LinuxScripts/blob/master/CODING-STANDARDS.md)

Agents should consult these standards when creating, modifying, or restructuring projects.

Project-specific requirements may extend or override these standards when necessary. Such exceptions should be documented.

## 3. Agent Skills

The canonical location for project-specific agent skills is:

`.agents/skills/`

- Skills should use the standard `SKILL.md` format.
- `.claude/skills` should be a symbolic link to `../.agents/skills`.
- Avoid maintaining duplicate copies of identical skills.
- Skills should be focused, reusable, and documented.

## 4. Video Game Standards

Video game projects should follow the [Basalt Game Standard](https://github.com/HungLo2020/Basalt/blob/main/STANDARDS.md) wherever practical.

This includes conventions for installation layout, data persistence, packaging, updates, and launcher integration.

Projects may deviate when technical requirements justify doing so.

## 5. Documentation

Every project should maintain a well-organized `docs/` directory.

- This directory is the canonical home for detailed project documentation.
- Documentation should be accurate, relevant, and maintained alongside implementation changes.
- The root `README.md` should provide a useful project overview and link to detailed documentation.
- Avoid unnecessary duplication of documentation.

## 6. Development Utilities

Every project should maintain a well-organized `DevUtils/` directory when development utilities are needed.

- This directory is the preferred home for development scripts, automation, testing infrastructure, benchmarking, and diagnostic tooling.
- Utilities should have descriptive names and a clear organizational structure.
- Related utilities should be grouped into appropriate subdirectories.
- Avoid duplicating functionality or introducing unnecessary tooling.
- Project-specific build and development utilities should be maintained with the project.

## 7. Preferred Programming Language

**Rust is the preferred language** for programs, applications, libraries, and other substantial software components.

Other languages may be used when dictated by platform requirements, existing architecture, interoperability, or clear technical advantages.

Do not rewrite existing, functioning components solely to satisfy a language preference.

## 8. Scripting and Automation

**Python is the preferred language** for development tooling, scripting, and automation when Rust is not an appropriate choice.

- Most `DevUtils/` scripts should be written in Python.
- Shell scripts are acceptable for simple command orchestration, bootstrapping, and platform-specific operations.
- Rust remains appropriate for tooling that benefits from native compilation, performance, type safety, or distribution as a standalone executable.
- Favor standard libraries and minimize unnecessary dependencies.

## 9. Applicability and Exceptions

These standards establish preferred conventions, not rigid architectural constraints.

- Existing functionality and correctness take precedence over cosmetic standardization.
- Do not reorganize a working project solely for consistency unless the benefits justify the changes.
- Project-specific instructions take precedence where they explicitly define an exception.
- New projects should follow these standards from the beginning wherever practical.