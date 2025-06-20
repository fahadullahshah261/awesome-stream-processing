import os
import sys
import asyncio
from contextlib import AsyncExitStack
from dataclasses import dataclass
from typing import Any
from anthropic import Anthropic
from dotenv import load_dotenv
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

load_dotenv()

@dataclass
class ModelConfig:
    model: str = "claude-3-haiku-20240307" 
    max_tokens: int = 1024
    temperature: float = 1.0
    context_window_tokens: int = 180000
    
class MCPConnection:
    def __init__(self, command: str, args=None, env=None):
        self.command = command
        self.args = args or []
        self.env = env
        self.session = None
        self._rw_ctx = None
        self._session_ctx = None

    async def __aenter__(self):
        self._rw_ctx = stdio_client(StdioServerParameters(
            command=self.command, args=self.args, env=self.env
        ))
        read, write = await self._rw_ctx.__aenter__()
        self._session_ctx = ClientSession(read, write)
        self.session = await self._session_ctx.__aenter__()
        await self.session.initialize()
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        try:
            if self._session_ctx:
                await self._session_ctx.__aexit__(exc_type, exc_val, exc_tb)
            if self._rw_ctx:
                await self._rw_ctx.__aexit__(exc_type, exc_val, exc_tb)
        except Exception as e:
            print(f"Error during cleanup: {e}")
        finally:
            self.session = None
            self._session_ctx = None
            self._rw_ctx = None

    async def list_tools(self) -> Any:
        response = await self.session.list_tools()
        return response.tools

    async def call_tool(self, tool_name: str, arguments: dict[str, Any]) -> Any:
        return await self.session.call_tool(tool_name, arguments=arguments)

class RisingWaveAgent:
    def __init__(self, system: str, mcp_command: str, mcp_args=None, mcp_env=None, config: ModelConfig | None = None, verbose: bool = False):
        self.system = system
        self.config = config or ModelConfig()
        self.verbose = verbose
        self.client = Anthropic(api_key=os.environ.get("ANTHROPIC_API_KEY", ""))
        self.mcp_command = mcp_command
        self.mcp_args = mcp_args or []
        self.mcp_env = mcp_env or None

    async def run_async(self, user_input: str) -> str:
        async with AsyncExitStack() as stack:
            mcp = await stack.enter_async_context(MCPConnection(
                command=self.mcp_command,
                args=self.mcp_args,
                env=self.mcp_env
            ))
            # List available tools
            tools = await mcp.list_tools()
            tool_dict = {tool.name: tool for tool in tools}

            # Prepare the Claude messages API call
            response = self.client.messages.create(
                model=self.config.model,
                max_tokens=self.config.max_tokens,
                temperature=self.config.temperature,
                system=self.system,
                messages=[{"role": "user", "content": user_input}],
                tools=[
                    {
                        "name": tool.name,
                        "description": getattr(tool, "description", ""),
                        "input_schema": getattr(tool, "inputSchema", {}),
                    }
                    for tool in tools
]
            )

            tool_calls = [block for block in response.content if block.type == "tool_use"]
            if tool_calls:
                tool_results = []
                for call in tool_calls:
                    try:
                        result = await mcp.call_tool(call.name, call.input)
                        tool_results.append({
                            "type": "tool_result",
                            "tool_use_id": call.id,
                            "content": str(result)
                        })
                    except Exception as e:
                        tool_results.append({
                            "type": "tool_result",
                            "tool_use_id": call.id,
                            "content": f"Error executing tool: {str(e)}",
                            "is_error": True
                        })

                final_response = self.client.messages.create(
                    model=self.config.model,
                    max_tokens=self.config.max_tokens,
                    temperature=self.config.temperature,
                    system=self.system,
                    messages=[
                        {"role": "user", "content": user_input},
                        {"role": "assistant", "content": [
                            {
                                "type": "tool_use",
                                "id": call.id,
                                "name": call.name,
                                "input": call.input
                            } for call in tool_calls
                        ]},
                        {"role": "user", "content": [
                            {
                                "type": "tool_result",
                                "tool_use_id": result["tool_use_id"],
                                "content": result["content"]
                            } for result in tool_results
                        ]}
                    ],
                    tools=[
                        {
                            "name": tool.name,
                            "description": getattr(tool, "description", ""),
                            "input_schema": getattr(tool, "inputSchema", {}),
                        }
                        for tool in tools
                    ]
                )
                final_text = "".join(block.text for block in final_response.content if hasattr(block, "text"))
                tool_output = "\n".join(result["content"] for result in tool_results if result["content"].strip())
                if tool_output and tool_output in final_text:
                    return final_text
               
                if not final_text.strip() and tool_output:
                    return f"Here is the result:\n{tool_output}"
       
                if tool_output:
                    return f"{final_text}\n\nHere is the result you requested:\n{tool_output}"
                return final_text
            else:
                return "".join(block.text for block in response.content if hasattr(block, "text"))

    def run(self, user_input: str) -> str:
        return asyncio.run(self.run_async(user_input))

if __name__ == "__main__":
    system_prompt = """You are an assistant to a Rising Wave database. Use tools when needed to answer questions about the database.\nBe concise, accurate, and only use tools when necessary."""
    mcp_command = "python"
    mcp_args = [os.path.join("risingwave-mcp", "src", "main.py")]
    agent = RisingWaveAgent(
    system=system_prompt,
    mcp_command=mcp_command,
    mcp_args=mcp_args,
    mcp_env=os.environ.copy(), 
    verbose=False
)
    print("\nRisingWave Agent Interactive Mode")
    print("Type 'exit' or 'quit' to end the session")
    print("----------------------------------------")

    while True:
        try:
            user_input = input("\nEnter your query: ").strip()
            if user_input.lower() in ['exit', 'quit']:
                print("\nEnding session. Goodbye!")
                break
            if not user_input:
                continue
            response = agent.run(user_input)
            print("\n", response)
        except KeyboardInterrupt:
            print("\n\nSession interrupted. Goodbye!")
            break
        except Exception as e:
            print(f"\nAn error occurred: {str(e)}")
            print("Please try again with a different query.")
        
