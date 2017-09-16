# Navraj Chohan
# Test for soap calls
# Test each exit point on the soap calls

import os
import SOAPpy
import sys

from appscale.datastore import helper_functions

PYTHON_PATH = os.environ.get("PYTHONPATH")

APPSCALE_HOME = os.environ.get("APPSCALE_HOME")
if APPSCALE_HOME:
  pass
else:
  APPSCALE_HOME = "/root/appscale"
  print "APPSCALE_HOME env var not set. Using default " + APPSCALE_HOME

APP_TABLE = "APPS__"
USER_TABLE = "USERS__"
DEFAULT_USER_LOCATION = ".flatfile_users"
DEFAULT_APP_LOCATION = ".flatfile_apps"
DEFAULT_DATASTORE = "cassandra"
DEFAULT_SSL_PORT = 4343
DEFAULT_PORT = 8080
IP_TABLE = "IPS___"
DEFAULT_ENCRYPTION = 1
VALID_DATASTORES = []
CERT_LOCATION = "/etc/appscale/certs/mycert.pem"
KEY_LOCATION = "/etc/appscale/certs/mykey.pem"
SECRET_LOCATION = "/etc/appscale/secret.key"
user_location = DEFAULT_USER_LOCATION
datastore_type = DEFAULT_DATASTORE
encryptOn = DEFAULT_ENCRYPTION
bindport = DEFAULT_SSL_PORT

ERROR_CODES = []
super_secret = ""
DEBUG = True
db = []
user_schema = []
app_schema = []

BAD_SECRET = "Error: bad secret"
#Navraj Chohan
app_location = "localhost"
encrypt = True
appname = ""
username = ""
allusers = False
allapps = False
def usage():
  print " -t for type of datastore"
  print " -a for the soap server address"
  print " -s for the secret"
  print " -p for the port to connect to"
  print " --http for a nonsecure connection"
  print " --appname for info on an app"
  print " --user for info on a user"
  print " --allusers for a list of all users"
  print " --allapps for a list of all apps"
  print " -h for this help menu"
for ii in range(1,len(sys.argv)):
  if sys.argv[ii] in ("-h", "--help"):
    print "help menu:"
    usage()
    sys.exit()
  elif sys.argv[ii] in ('-a', "--apps"):
    print "apps location set to ",sys.argv[ii+ 1]
    app_location = sys.argv[ii + 1]
    ii += 1
  elif sys.argv[ii] in ('-t', "--type"):
    print "setting datastore type to ",sys.argv[ii+1]
    datastore_type = sys.argv[ii + 1]
    ii += 1
  elif sys.argv[ii] in ('-p', "--port"):
    print "opening on port ", sys.argv[ii+1]
    bindport = int(sys.argv[ii + 1] )
    ii += 1
  elif sys.argv[ii] in ('-s','--secret'):
    print "Your secret is safe with me. shhhhh!"
    super_secret = sys.argv[ii + 1]
    ii += 1
  elif sys.argv[ii] in ('--http'):
    print "The connection is no longer encryptyed"
    encrypt = 0
  elif sys.argv[ii] in ('--appname'):
    appname = sys.argv[ii + 1]
    ii += 1
  elif sys.argv[ii] in ("--username"):
    username = sys.argv[ii + 1]
    ii += 1
  elif sys.argv[ii] in ('--allapps'):
    allapps  = True
  elif sys.argv[ii] in ("--allusers"):
    allusers = True
  else:
    pass

if not super_secret:
  with open(SECRET_LOCATION, 'r') as file_handle:
    super_secret = file_handle.read()

print "address for server",app_location
print "binding port:",bindport
print "secret:",super_secret
print "encrypt:",encrypt
if encrypt:
  server = SOAPpy.SOAPProxy("https://" + app_location + ":" + str(bindport))
else:
  server = SOAPpy.SOAPProxy("http://" + app_location + ":" + str(bindport))

def createUser():
  username = helper_functions.random_string(10) 
  username += "@"
  username += helper_functions.random_string(5)
  username += "."
  username += helper_functions.random_string(3)
  password = helper_functions.random_string(10)
  return username, password

def createApp():
  name = helper_functions.random_string(10)
  tar = helper_functions.random_string(1000)
  return name, tar

def err(test_num, code):
  print "Failed for test at " + sys.argv[0] + ":" + str(test_num) + \
  " with unexpected output of: " + str(code)
  exit(1)

if username:
  print "======================"
  print "User data for given user:"
  ret = server.get_user_data(username, super_secret)
  print ret
  print "======================"
  exit(0)

if allusers:
  print server.get_all_users(super_secret)
  exit(0)

ret = server.does_user_exist("xxx", "xxx")
if ret != BAD_SECRET:
  err(helper_functions.lineno(), ret)

ret = server.is_user_enabled("xxx", "xxx")
if ret != BAD_SECRET:
  err(helper_functions.lineno(), ret)

ret = server.get_all_users("xxx")
if ret != BAD_SECRET:
  err(helper_functions.lineno(), ret)

ret = server.get_user_data("xxx", "xxx")
if ret != BAD_SECRET:
  err(helper_functions.lineno(), ret)

ret = server.commit_new_user("xxx", "xxx", "user", "xxx")
if ret != BAD_SECRET:
  err(helper_functions.lineno(), ret)

ret = server.commit_new_token("xxx", "xxx", "xxx", "xxx")
if ret != BAD_SECRET:
  err(helper_functions.lineno(), ret)

ret = server.delete_user("xxx", "xxx")
if ret != BAD_SECRET:
  err(helper_functions.lineno(), ret)

ret = server.change_password("xxx", "xxx", "xxx")
if ret != BAD_SECRET:
  err(helper_functions.lineno(), ret)

ret = server.disable_user("xxx", "xxx")
if ret != BAD_SECRET:
  err(helper_functions.lineno(), ret)

ret = server.enable_user("xxx", "xxx")
if ret != BAD_SECRET:
  err(helper_functions.lineno(), ret)

ret = server.is_user_enabled("xxx", "xxx")
if ret != BAD_SECRET:
  err(helper_functions.lineno(), ret)

##########################################################
# Test if apps/users are enabled or exists when they don't
##########################################################
app = createApp()
user = createUser()

ret = server.is_user_enabled(user[0], super_secret)
if ret != "false":
  err(helper_functions.lineno(), ret)

ret = server.does_user_exist(user[0], super_secret)
if ret != "false":
  print user[0]
  err(helper_functions.lineno(), ret)

ret = server.get_all_users(super_secret)
if "____" not in ret:
  print "Make sure you run appscale with at least one user"
  err(helper_functions.lineno(), ret)

ret = server.get_user_data(user[0], super_secret)
if "Error" not in ret:
  err(helper_functions.lineno(), ret)

ret = server.delete_user(user[0], super_secret)
if ret != "false":
  err(helper_functions.lineno(), ret)

ret = server.change_password(user[0], user[1], super_secret)
if "Error" not in ret:
  err(helper_functions.lineno(), ret)

ret = server.change_password(user[0], "", super_secret)
if "Error" not in ret:
  err(helper_functions.lineno(), ret)

ret = server.disable_user(user[0], super_secret)
if "Error" not in ret:
  err(helper_functions.lineno(), ret)

ret = server.enable_user(user[0], super_secret)
if "Error" not in ret:
  err(helper_functions.lineno(), ret)

ret = server.commit_new_token(user[0], "xxx", "xxx", super_secret)
if ret != "Error: User does not exist":
  err(helper_functions.lineno(), ret)

#########################################
# Test where user is not an email address
#########################################
ret = server.commit_new_user("xxx", "xxx", "user", super_secret)
if "Error" not in ret:
  err(helper_functions.lineno(), ret)

###################
# Commit a new user
###################
ret = server.commit_new_user(user[0], user[1], "user", super_secret)
if ret != "true":
  err(helper_functions.lineno(), ret)
###################
# Commit user twice
###################
ret = server.commit_new_user(user[0], user[1], "user", super_secret)
if ret != "Error: user already exists":
  err(helper_functions.lineno(), ret)

ret = server.does_user_exist(user[0], super_secret)
if ret != "true":
  err(helper_functions.lineno(), ret)
#######################################
# Retrieve the user's data with no apps
#######################################
ret = server.get_user_data(user[0], super_secret)
if user[0] not in ret or user[1] not in ret:
  err(helper_functions.lineno(), ret)
#################
# Change password
#################
newpw = helper_functions.random_string(10)
ret = server.change_password(user[0], newpw, super_secret)
if ret != "true":
  err(helper_functions.lineno(), ret)
#######################################
# Retrieve the user's data with new pw 
#######################################
ret = server.get_user_data(user[0], super_secret)
if user[0] not in ret or newpw not in ret:
  err(helper_functions.lineno(), ret)
######################
# Change password back
######################
ret = server.change_password(user[0], user[1], super_secret)
if ret != "true":
  err(helper_functions.lineno(), ret)
#######################################
# Retrieve the user's data with old pw 
#######################################
ret = server.get_user_data(user[0], super_secret)
if user[0] not in ret or user[1] not in ret:
  err(helper_functions.lineno(), ret)
################################
# Enable an already enabled user
################################
ret = server.enable_user(user[0], super_secret)
if "Error" not in ret:
  err(helper_functions.lineno(), ret)
########################
# Committing a new token
########################
token = helper_functions.random_string(10)
token_exp = helper_functions.random_string(10)
ret = server.commit_new_token(user[0], token, token_exp, super_secret)
if ret != "true":
  err(helper_functions.lineno(), ret)
##################
# Disable the user
##################
ret = server.disable_user(user[0], super_secret)
if ret != "true":
  err(helper_functions.lineno(), ret)
##################
# Disable twice
##################
ret = server.disable_user(user[0], super_secret)
if ret != "Error: Trying to disable a user twice":
  err(helper_functions.lineno(), ret)
###############################################
# Try and fail to change the disabled user's pw
###############################################
ret = server.change_password(user[0], "xxx", super_secret)
if ret != "Error: User must be enabled to change password":
  err(helper_functions.lineno(), ret)
###################################
# User is disabled, enable the user
###################################
ret = server.is_user_enabled(user[0], super_secret)
if ret != "false":
  err(helper_functions.lineno(), ret)
##################
# Enable user
##################
ret = server.enable_user(user[0], super_secret)
if ret != "true":
  err(helper_functions.lineno(), ret)
##################
# User is enabled
##################
ret = server.is_user_enabled(user[0], super_secret)
if ret != "true":
  err(helper_functions.lineno(), ret)
###################
# Delete user
###################
ret = server.delete_user(user[0], super_secret)
if ret != "Error: unable to delete active user. Disable user first":
  err(helper_functions.lineno(), ret)
#########################
# Disable user and delete
#########################
ret = server.disable_user(user[0], super_secret)
if ret != "true":
  err(helper_functions.lineno(), ret)
ret = server.delete_user(user[0], super_secret)
if ret != "true":
  err(helper_functions.lineno(), ret)
##########################
# Create the same user now
##########################
ret = server.commit_new_user(user[0], user[1], "user", super_secret)
if ret != "true":
  err(helper_functions.lineno(), ret)
ret = server.get_user_data(user[0], super_secret)
if user[0] not in ret:
  err(helper_functions.lineno(), ret)
ret = server.does_user_exist(user[0], super_secret)
if ret != "true":
  err(helper_functions.lineno(), ret)
##########################
# Get all users
##########################
ret = server.get_all_users(super_secret)
if user[0] not in ret:
  err(helper_functions.lineno(), ret)
print "SUCCESS. All is well in the world of AppScale and Soap"
