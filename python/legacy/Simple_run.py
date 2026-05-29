from gpt_researcher import GPTResearcher
import asyncio
import os

#--------------------------------------------------------------------------------------------------------------------------------------------------------------------------

# Load API keys from files
def load_api_key(file_path: str) -> str:
    with open(file_path, 'r') as f:
        return f.read().strip()

OPENAI_API_KEY_FILE = r"C:\Users\dafl\OneDrive - Folkehelseinstituttet\API keys\tore_vkm_openai.txt"
TAVILY_API_KEY_FILE = r"C:\Users\dafl\OneDrive - Folkehelseinstituttet\API keys\Tavily_key.txt"

os.environ['OPENAI_API_KEY'] = load_api_key(OPENAI_API_KEY_FILE)
os.environ['TAVILY_API_KEY'] = load_api_key(TAVILY_API_KEY_FILE)

 #--------------------------------------------------------------------------------------------------------------------------------------------------------------------------

async def main():

    # Query
    query = "what is AI?"

    # Report Type
    report_type = "research_report"

    # Initialize the researcher
    researcher = GPTResearcher(query=query, report_type=report_type, config_path=None)
    # Conduct research on the given query
    await researcher.conduct_research()
    # Write the report
    report = await researcher.write_report()

    return report

if __name__ == "__main__":
    asyncio.run(main())