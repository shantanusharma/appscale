#!/usr/bin/env python
""" View all application entities. """

import os
import sys

from dbconstants import *
import appscale_datastore_batch

_MAX_ENTITIES = 1000000

def get_entities(table, schema, db, first_key, last_key):
  """ Gets entities from a table.
    
  Args:
    table: Name of the table
    schema: The schema of table to get from
    db: The database accessor
    first_key: The entity key to start from
    last_key: The entity key to stop at
  Returns: 
    The entire table up to _MAX_ENTITIES.
  """
  return db.range_query(table, schema, first_key, last_key, _MAX_ENTITIES)

def view_all(entities, table, db):
  """ View all entities for a table
  
  Args:
    entities: Shows all entities in a list
    table: The table these entities are from
    db: database accessor
  """
  print 
  print "TABLE:",table
  for ii in entities:
    print ii
  print

def main(argv):
  # Parse args.
  DB_TYPE="cassandra"
  first_key = ""
  last_key = ""

  if len(argv) > 2:
    print "usage: ./view_all_records.py [app_id]"
    exit(1)

  if len(argv) == 2:
    first_key = argv[1]
    last_key = first_key + TERMINATING_STRING
  
  # Fetch entities.
  db = appscale_datastore_batch.DatastoreFactory.getDatastore(DB_TYPE)

  tables_to_schemas = {
    APP_ENTITY_TABLE: APP_ENTITY_SCHEMA,
    ASC_PROPERTY_TABLE: PROPERTY_SCHEMA,
    DSC_PROPERTY_TABLE: PROPERTY_SCHEMA,
    COMPOSITE_TABLE: COMPOSITE_SCHEMA,
    APP_KIND_TABLE: APP_KIND_SCHEMA,
    METADATA_TABLE: METADATA_SCHEMA,
    DATASTORE_METADATA_TABLE: DATASTORE_METADATA_SCHEMA, 
  }

  for table in tables_to_schemas:
    entities = get_entities(table, tables_to_schemas[table], 
                            db, first_key, last_key)
    view_all(entities, table, db)

if __name__ == "__main__":
  try:
    main(sys.argv)
  except:
    raise
