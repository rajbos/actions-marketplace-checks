const { ActionsMarketplaceClient } = require('@devops-actions/actions-marketplace-client');

async function getActionsCount() {
  const apiUrl = process.argv[2];
  const functionKey = process.argv[3];
  
  // Validate arguments
  if (!apiUrl) {
    console.error('API URL is required');
    process.exit(1);
  }

  if (!functionKey) {
    console.error('Function key is required');
    process.exit(1);
  }

  // Validate URL format
  if (apiUrl.length === 0) {
    console.error('API URL cannot be empty (length: 0)');
    process.exit(1);
  }

  // Validate function key format
  if (functionKey.length === 0) {
    console.error('Function key cannot be empty (length: 0)');
    process.exit(1);
  }

  console.log('Initializing Actions Marketplace Client...');
  const client = new ActionsMarketplaceClient({ apiUrl, functionKey });
  
  try {
    console.log('Getting actions count from API...');
    const actions = await client.listActions();
    const count = actions ? actions.length : 0;
    
    console.log('Successfully retrieved actions list');
    console.log('Actions count:', count);
    
    // Output count for PowerShell to parse
    console.log('__COUNT_START__');
    console.log(count);
    console.log('__COUNT_END__');
  } catch (error) {
    console.error('Failed to get actions count:', error.message);
    console.error('Error details:', error);
    console.error('Stack trace:', error.stack);
    process.exit(1);
  }
}

if (require.main === module) {
  getActionsCount().catch(error => {
    console.error('Fatal error:', error);
    process.exit(1);
  });
}

module.exports = {
  getActionsCount
};
