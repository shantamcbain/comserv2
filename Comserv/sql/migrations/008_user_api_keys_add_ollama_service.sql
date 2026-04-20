-- Add 'ollama' to the service ENUM in user_api_keys
-- Required for storing Ollama cloud API keys (used for web search via ollama.com/api/web_search)
-- Run on every DB instance that has the user_api_keys table.

ALTER TABLE `user_api_keys`
  MODIFY COLUMN `service` ENUM('grok','ollama','openai','claude','gemini','anthropic','cohere') NOT NULL;
