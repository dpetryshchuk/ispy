const List<Map<String, dynamic>> kIspyToolDefinitions = [
  {
    'name': 'read_file',
    'description': 'Read the contents of a file.',
    'parameters': {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': 'Relative path to the file.'},
      },
      'required': ['path'],
    },
  },
  {
    'name': 'write_file',
    'description': 'Create or overwrite a file with content.',
    'parameters': {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': 'Relative path to write to.'},
        'content': {'type': 'string', 'description': 'Content to write.'},
      },
      'required': ['path', 'content'],
    },
  },
  {
    'name': 'list_directory',
    'description': 'List files and folders in a directory.',
    'parameters': {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': 'Relative path to directory.'},
      },
      'required': ['path'],
    },
  },
  {
    'name': 'create_directory',
    'description': 'Create a new directory (and any missing parents).',
    'parameters': {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': 'Relative path to create.'},
      },
      'required': ['path'],
    },
  },
  {
    'name': 'search_files',
    'description': 'Search for a query string across all markdown files.',
    'parameters': {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': 'Text to search for.'},
      },
      'required': ['query'],
    },
  },
  {
    'name': 'move_file',
    'description': 'Move or rename a file.',
    'parameters': {
      'type': 'object',
      'properties': {
        'from': {'type': 'string', 'description': 'Current relative path.'},
        'to': {'type': 'string', 'description': 'New relative path.'},
      },
      'required': ['from', 'to'],
    },
  },
];
