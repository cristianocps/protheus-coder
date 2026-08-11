"""Protheus Coder MCP server.

A small, auditable MCP surface (FastMCP over Streamable HTTP) that fronts the
Claude Agent SDK. Instead of exposing Claude Code's raw tools to Copilot Studio,
it publishes a handful of high-level, read-only tools for understanding code in
Azure DevOps repositories.
"""

__all__ = ["config"]
