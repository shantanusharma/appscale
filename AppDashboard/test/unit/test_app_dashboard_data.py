from flexmock import flexmock
import logging
import re
import sys
import os
import unittest

sys.path.append(os.path.join(os.path.dirname(__file__), "../../lib/"))
import app_dashboard_data
from app_dashboard_data import AppDashboardData
from app_dashboard_helper import AppDashboardHelper

sys.path.append(os.path.join(os.path.expanduser("~"), "appscale/AppServer/"))
from google.appengine.ext import ndb
from google.appengine.api import users


class TestAppDashboardData(unittest.TestCase):


  def setUp(self):
    fake_root = flexmock()
    fake_root.head_node_ip = '1.1.1.1'
    fake_root.table = 'table'
    fake_root.replication = 3
    fake_root.should_receive('put').and_return()

    flexmock(app_dashboard_data).should_receive('DashboardDataRoot') \
      .and_return(fake_root)
    flexmock(AppDashboardData).should_receive('get_by_id') \
      .with_args(app_dashboard_data.DashboardDataRoot,
        AppDashboardData.ROOT_KEYNAME)\
      .and_return(fake_root)

  def setupUserInfoMocks(self):
    user_info1 = flexmock(name='UserInfo', email='a@a.com',
                          is_user_cloud_admin=True, can_upload_apps=True,
                          owned_apps=['app1',
                                      'app2'], dash_layout_settings=None)
    user_info1.should_receive('put').and_return()

    user_info2 = flexmock(name='UserInfo', email='b@a.com',
                          is_user_cloud_admin=False, can_upload_apps=True,
                          owned_apps=['app2'],
                          dash_layout_settings=None)
    user_info2.should_receive('put').and_return()

    user_info3 = flexmock(name='UserInfo', email='c@a.com',
                          is_user_cloud_admin=False, can_upload_apps=False,
                          owned_apps=['app2'],
                          dash_layout_settings=None)
    user_info3.should_receive('put').and_return()

    user_info4 = flexmock(name='UserInfo', email='d@a.com',
                          is_user_cloud_admin=False, can_upload_apps=False,
                          owned_apps=[],
                          dash_layout_settings=None)
    user_info4.should_receive('put').and_return()

    flexmock(app_dashboard_data).should_receive('UserInfo')\
      .and_return(user_info1)
    flexmock(AppDashboardData).should_receive('get_by_id')\
      .with_args(app_dashboard_data.UserInfo, re.compile('@a.com'))\
      .and_return(user_info1) \
      .and_return(user_info2) \
      .and_return(user_info3) \
      .and_return(user_info4)


  def setupFakePutsAndDeletes(self):
    flexmock(ndb).should_receive('put_multi').and_return()
    flexmock(ndb).should_receive('delete_multi').and_return()


  def setupUsersAPIMocks(self):
    flexmock(users)
    users.should_receive('get_current_user').and_return(None) \
      .and_return(flexmock(email=lambda:'a@a.com')) \
      .and_return(flexmock(email=lambda:'b@a.com')) \
      .and_return(flexmock(email=lambda:'c@a.com')) \
      .and_return(flexmock(email=lambda:'d@a.com'))


  def test_init(self):
    data1 = AppDashboardData()
    self.assertNotEquals(None, data1.helper)

    data2 = AppDashboardData(flexmock())
    self.assertNotEquals(None, data2.helper)


  def test_get_monitoring_url(self):
    fake_ip  = '1.1.1.1.'
    flexmock(AppDashboardData).should_receive('get_head_node_ip')\
    .and_return(fake_ip).once()

    data1 = AppDashboardData()
    url = data1.get_monitoring_url()
    self.assertEquals(url, "http://{0}:{1}".format(fake_ip,
      AppDashboardData.MONITOR_PORT))


  def test_get_head_node_ip(self):
    data1 = AppDashboardData()
    fake_ip  = '1.1.1.1'
    self.assertEquals(data1.get_head_node_ip(), fake_ip)


  def test_update_head_node_ip(self):
    fake_ip  = '1.1.1.1'
    self.assertEquals(fake_ip, AppDashboardData().update_head_node_ip())


  def test_get_database_info(self):
    data1 = AppDashboardData()
    output = data1.get_database_info()
    self.assertEquals(output['table'], 'table')
    self.assertEquals(output['replication'], 3)

  def test_update_users(self):
    flexmock(ndb).should_receive('put_multi').and_return()
    flexmock(AppDashboardHelper).should_receive('list_all_users')\
      .and_return(['a@a.com', 'b@a.com', 'c@a.com', 'd@a.com']).once()
    flexmock(AppDashboardHelper).should_receive('is_user_cloud_admin')\
      .with_args('a@a.com').and_return(True).once()
    flexmock(AppDashboardHelper).should_receive('is_user_cloud_admin')\
      .with_args('b@a.com').and_return(False).once()
    flexmock(AppDashboardHelper).should_receive('is_user_cloud_admin')\
      .with_args('c@a.com').and_return(False).once()
    flexmock(AppDashboardHelper).should_receive('is_user_cloud_admin') \
      .with_args('d@a.com').and_return(False).once()

    flexmock(AppDashboardHelper).should_receive('can_upload_apps')\
      .with_args('a@a.com').and_return(True).once()
    flexmock(AppDashboardHelper).should_receive('can_upload_apps')\
      .with_args('b@a.com').and_return(True).once()
    flexmock(AppDashboardHelper).should_receive('can_upload_apps')\
      .with_args('c@a.com').and_return(False).once()
    flexmock(AppDashboardHelper).should_receive('can_upload_apps') \
      .with_args('d@a.com').and_return(False).once()

    flexmock(AppDashboardHelper).should_receive('get_owned_apps')\
      .with_args('a@a.com').and_return(['app1', 'app2']).once()
    flexmock(AppDashboardHelper).should_receive('get_owned_apps')\
      .with_args('b@a.com').and_return(['app2']).once()
    flexmock(AppDashboardHelper).should_receive('get_owned_apps')\
      .with_args('c@a.com').and_return(['app2']).once()
    flexmock(AppDashboardHelper).should_receive('get_owned_apps') \
      .with_args('d@a.com').and_return([]).once()

    self.setupUserInfoMocks()

    data1 = AppDashboardData()

    output = data1.update_users()
    self.assertEquals(len(output), 4)
    self.assertTrue(output[0].is_user_cloud_admin)
    self.assertFalse(output[1].is_user_cloud_admin)
    self.assertFalse(output[2].is_user_cloud_admin)
    self.assertFalse(output[3].is_user_cloud_admin)
    self.assertTrue(output[0].can_upload_apps)
    self.assertTrue(output[1].can_upload_apps)
    self.assertFalse(output[2].can_upload_apps)
    self.assertFalse(output[3].can_upload_apps)
    self.assertEqual(self.flatten_dash_layout(output[0].dash_layout_settings),
                     self.user_info1_cloud_admin_dict)
    self.assertEqual(self.flatten_dash_layout(output[1].dash_layout_settings),
                     self.user_info2_can_upload_apps_dict)
    self.assertEqual(self.flatten_dash_layout(output[2].dash_layout_settings),
                     self.user_info3_cannot_upload_apps_dict)
    self.assertEqual(self.flatten_dash_layout(output[3].dash_layout_settings),
                     self.user_info4_cannot_upload_and_owns_no_apps_dict)


  def test_get_owned_apps(self):
    # slip in some fake users
    self.setupUserInfoMocks()

    # mock out the App Engine Users API
    self.setupUsersAPIMocks()

    data1 = AppDashboardData()

    # First call, not logged in.
    output = data1.get_owned_apps()
    self.assertEqual(len(output), 0)

    # First user: a@a.com, apps=app1,app2
    output = data1.get_owned_apps()
    self.assertTrue('app1' in output)
    self.assertTrue('app2' in output)

    # Second user: b@a.com, apps=app2
    output = data1.get_owned_apps()
    self.assertTrue('app2' in output)

    # Third user: c@a.com, admin=app2.
    output = data1.get_owned_apps()
    self.assertTrue('app2' in output)

    # Fourth user: d@a.com, admin=None.
    output = data1.get_owned_apps()
    self.assertTrue(not output)


  def test_is_user_cloud_admin(self):
    # slip in some fake users
    self.setupUserInfoMocks()

    # mock out the App Engine Users API
    self.setupUsersAPIMocks()

    data1 = AppDashboardData()

    # First call, not logged in.
    self.assertFalse(data1.is_user_cloud_admin())

    # First user: a@a.com, admin=True.
    self.assertTrue(data1.is_user_cloud_admin())

    # Second user: b@a.com, admin=False.
    self.assertFalse(data1.is_user_cloud_admin())

    # Third user: c@a.com, admin=False.
    self.assertFalse(data1.is_user_cloud_admin())

    # Fourth user: d@a.com, admin=False.
    self.assertFalse(data1.is_user_cloud_admin())


  def test_can_upload_apps(self):
    # slip in some fake users
    self.setupUserInfoMocks()

    # mock out the App Engine Users API
    self.setupUsersAPIMocks()

    data1 = AppDashboardData()

    # First call, not logged in.
    self.assertFalse(data1.can_upload_apps())

    # First user: a@a.com, upload=True.
    self.assertTrue(data1.can_upload_apps())

    # Second user: b@a.com, upload=True.
    self.assertTrue(data1.can_upload_apps())

    # Third user: c@a.com, upload=False.
    self.assertFalse(data1.can_upload_apps())

    # Fourth user: d@a.com, upload=False.
    self.assertFalse(data1.can_upload_apps())

  #a@a.com is cloud admin and can upload apps and owns apps
  user_info1_cloud_admin_dict = {
    "nav":["app_management", "appscale_management",
           "debugging_monitoring"],
    "panel":["app_console","upload_app","cloud_stats","database_stats",
             "memcache_stats"]
  }
  #b@a.com is not cloud admin and can upload apps and owns apps
  user_info2_can_upload_apps_dict = {
    "nav":["app_management",
           "debugging_monitoring"],
    "panel":["app_console","upload_app"]
  }
  #c@a.com is not cloud admin and cannot upload apps and owns apps
  user_info3_cannot_upload_apps_dict = {
    "nav":["debugging_monitoring"],
    "panel":["app_console","upload_app"]
  }
  #d@a.com is not cloud admin and cannot upload apps and does not own apps
  user_info4_cannot_upload_and_owns_no_apps_dict = {"nav":[],"panel":[
    "app_console","upload_app"]}

  def test_set_dash_layout_settings_no_argument(self):
    # slip in some fake users
    self.setupUserInfoMocks()

    # mock out the App Engine Users API
    self.setupUsersAPIMocks()

    data1 = AppDashboardData()

    # First call, not logged in.
    self.assertEqual(data1.set_dash_layout_settings(), None)

    # First user: a@a.com, upload=True, cloud_admin=True
    self.assertEqual(self.flatten_dash_layout(
      data1.set_dash_layout_settings(values=None)),
      self.user_info1_cloud_admin_dict)

    # Second user: b@a.com, upload=True, cloud_admin=False
    self.assertEqual(self.flatten_dash_layout(
      data1.set_dash_layout_settings(values=None)),
      self.user_info2_can_upload_apps_dict)

    # Third user: c@a.com, upload=False, cloud_admin=False
    self.assertEqual(self.flatten_dash_layout(
      data1.set_dash_layout_settings(values=None)),
      self.user_info3_cannot_upload_apps_dict)

    # Fourth user: d@a.com, upload=False, cloud_admin=False
    self.assertEqual(self.flatten_dash_layout(
      data1.set_dash_layout_settings(values=None)),
      self.user_info4_cannot_upload_and_owns_no_apps_dict)

  def test_set_dash_layout_settings_with_argument(self):
    # slip in some fake users
    self.setupUserInfoMocks()

    # mock out the App Engine Users API
    self.setupUsersAPIMocks()

    data1 = AppDashboardData()
    #Sending new dictionaries

    user_setting = {
      "nav":["debugging_monitoring", "appscale_management", "app_management",
             "invalid_key"],
      "panel":["cloud_stats","database_stats","upload_app","app_console",
               "memcache_stats"]
    }

    self.assertEqual(data1.set_dash_layout_settings(values=user_setting), None)

    user_setting = {
      "nav":["debugging_monitoring", "appscale_management", "app_management",
             "invalid_key"],
      "panel":["cloud_stats","database_stats","upload_app","app_console",
               "memcache_stats"]
    }

    # First user: a@a.com, upload=True, cloud_admin=True
    user1_should_return = {
      "nav":["debugging_monitoring", "appscale_management", "app_management"],
      "panel":["cloud_stats","database_stats","upload_app","app_console",
               "memcache_stats"]
    }
    self.assertEqual(self.flatten_dash_layout(
      data1.set_dash_layout_settings(values=user_setting)),
      user1_should_return)

    # Second user: b@a.com, upload=True, cloud_admin=False
    user_setting = {
      "nav":["debugging_monitoring", "appscale_management", "app_management",
             "invalid_key"],
      "panel":["cloud_stats","database_stats","upload_app","app_console",
               "memcache_stats"]
    }
    user2_should_return = {
      "nav":["debugging_monitoring", "app_management"],
      "panel":["upload_app","app_console"]
    }
    self.assertEqual(self.flatten_dash_layout(
      data1.set_dash_layout_settings(values=user_setting)),
      user2_should_return)

    # Third user: c@a.com, upload=False, cloud_admin=False
    user_setting = {
      "nav":["debugging_monitoring", "appscale_management", "app_management",
             "invalid_key"],
      "panel":["cloud_stats","database_stats","upload_app","app_console",
               "memcache_stats"]
    }
    user3_should_return = {
      "nav":["debugging_monitoring"],
      "panel":["upload_app","app_console"]
    }
    self.assertEqual(self.flatten_dash_layout(
      data1.set_dash_layout_settings(values=user_setting)),
      user3_should_return)

    # Fourth user: d@a.com, upload=False, cloud_admin=False
    user_setting = {
      "nav":["debugging_monitoring", "appscale_management", "app_management",
             "invalid_key"],
      "panel":["cloud_stats","database_stats","upload_app","app_console",
               "memcache_stats"]
    }
    user4_should_return = {
      "nav":[],
      "panel":["upload_app","app_console"]
    }
    self.assertEqual(self.flatten_dash_layout(
      data1.set_dash_layout_settings(values=user_setting)),
      user4_should_return)

  def test_get_dash_layout_settings(self):
    # slip in some fake users
    self.setupUserInfoMocks()

    # mock out the App Engine Users API
    self.setupUsersAPIMocks()

    data1 = AppDashboardData()

    # First call, not logged in.
    self.assertEqual(data1.get_dash_layout_settings(), {})

    # First user: a@a.com, upload=True, cloud_admin=True
    self.assertEqual(self.flatten_dash_layout(
      data1.get_dash_layout_settings()),
      self.user_info1_cloud_admin_dict)

    # Second user: b@a.com, upload=True, cloud_admin=False
    self.assertEqual(self.flatten_dash_layout(
      data1.get_dash_layout_settings()),
      self.user_info2_can_upload_apps_dict)

    # Third user: c@a.com, upload=False, cloud_admin=False
    self.assertEqual(self.flatten_dash_layout(
      data1.get_dash_layout_settings()),
      self.user_info3_cannot_upload_apps_dict)

    # Fourth user: d@a.com, upload=False, cloud_admin=False
    self.assertEqual(self.flatten_dash_layout(
      data1.get_dash_layout_settings()),
      self.user_info4_cannot_upload_and_owns_no_apps_dict)


  def test_rebuild_dash_layout_settings_dict_default(self):
    # slip in some fake users
    self.setupUserInfoMocks()

    # mock out the App Engine Users API
    self.setupUsersAPIMocks()

    data1 = AppDashboardData()

    user1 = data1.get_by_id(app_dashboard_data.UserInfo, "a@a.com")
    user2 = data1.get_by_id(app_dashboard_data.UserInfo, "b@a.com")
    user3 = data1.get_by_id(app_dashboard_data.UserInfo, "c@a.com")
    user4 = data1.get_by_id(app_dashboard_data.UserInfo, "d@a.com")

    # First call, not logged in.
    self.assertEqual({}, data1.rebuild_dash_layout_settings_dict(email=None))

    # First user: a@a.com, upload=True, cloud_admin=True
    self.assertEqual(self.user_info1_cloud_admin_dict, self.flatten_dash_layout(
                     data1.rebuild_dash_layout_settings_dict(
                       email=user1.email)))

    # Second user: b@a.com, upload=True, cloud_admin=False
    self.assertEqual(self.user_info2_can_upload_apps_dict,
                     self.flatten_dash_layout(
                       data1.rebuild_dash_layout_settings_dict(
                         email=user2.email)))

    # Third user: c@a.com, upload=False, cloud_admin=False
    self.assertEqual(self.user_info3_cannot_upload_apps_dict,
                     self.flatten_dash_layout(
                       data1.rebuild_dash_layout_settings_dict(
                         email=user3.email)))

    # Fourth user: d@a.com, upload=False, cloud_admin=False
    self.assertEqual(self.user_info4_cannot_upload_and_owns_no_apps_dict,
                     self.flatten_dash_layout(
                       data1.rebuild_dash_layout_settings_dict(
                         email=user4.email)))


  def test_rebuild_dash_layout_settings_dict_custom(self):
    # slip in some fake users
    self.setupUserInfoMocks()

    # mock out the App Engine Users API
    self.setupUsersAPIMocks()

    data1 = AppDashboardData()

    user1 = data1.get_by_id(app_dashboard_data.UserInfo, "a@a.com")
    user2 = data1.get_by_id(app_dashboard_data.UserInfo, "b@a.com")
    user3 = data1.get_by_id(app_dashboard_data.UserInfo, "c@a.com")
    user4 = data1.get_by_id(app_dashboard_data.UserInfo, "d@a.com")

    user_setting = {
      "nav":["debugging_monitoring", "appscale_management", "app_management",
             "invalid_key"],
      "panel":["cloud_stats","database_stats","upload_app","app_console",
               "memcache_stats"]
    }
    # First user: a@a.com, upload=True, cloud_admin=True
    user1_should_return = {
      "nav":["debugging_monitoring", "appscale_management", "app_management"],
      "panel":["cloud_stats","database_stats","upload_app","app_console",
               "memcache_stats"]
    }
    self.assertEqual(self.flatten_dash_layout(
      data1.set_dash_layout_settings(values=user_setting, user_info=user1)),
      user1_should_return)
    self.assertEqual(user1_should_return,
                     self.flatten_dash_layout(data1.rebuild_dash_layout_settings_dict(
      email=user1.email)))

    # Second user: b@a.com, upload=True, cloud_admin=False
    user_setting = {
      "nav":["debugging_monitoring", "appscale_management", "app_management",
             "invalid_key"],
      "panel":["cloud_stats","database_stats","upload_app","app_console",
               "memcache_stats"]
    }
    user2_should_return = {
      "nav":["debugging_monitoring", "app_management"],
      "panel":["upload_app","app_console"]
    }
    self.assertEqual(self.flatten_dash_layout(
      data1.set_dash_layout_settings(values=user_setting, user_info=user2)),
      user2_should_return)
    self.assertEqual(user2_should_return,
                     self.flatten_dash_layout(data1.rebuild_dash_layout_settings_dict(
                       email=user2.email)))

    # Third user: c@a.com, upload=False, cloud_admin=False
    user_setting = {
      "nav":["debugging_monitoring", "appscale_management", "app_management",
             "invalid_key"],
      "panel":["cloud_stats","database_stats","upload_app","app_console",
               "memcache_stats"]
    }
    user3_should_return = {
      "nav":["debugging_monitoring"],
      "panel":["upload_app","app_console"]
    }
    self.assertEqual(self.flatten_dash_layout(
      data1.set_dash_layout_settings(values=user_setting, user_info=user3)),
      user3_should_return)
    self.assertEqual(user3_should_return,
                     self.flatten_dash_layout(data1.rebuild_dash_layout_settings_dict(
                       email=user3.email)))

    # Fourth user: d@a.com, upload=False, cloud_admin=False
    user_setting = {
      "nav":["debugging_monitoring", "appscale_management", "app_management",
             "invalid_key"],
      "panel":["cloud_stats","database_stats","upload_app","app_console",
               "memcache_stats"]
    }
    user4_should_return = {
      "nav":[],
      "panel":["upload_app","app_console"]
    }
    self.assertEqual(self.flatten_dash_layout(
      data1.set_dash_layout_settings(values=user_setting, user_info=user4)),
      user4_should_return)
    self.assertEqual(user4_should_return,
                     self.flatten_dash_layout(data1.rebuild_dash_layout_settings_dict(
                       email=user4.email)))

  def flatten_dash_layout(self, input_dict):
    if input_dict.get('nav'):
      flatten_nav = [key for key_dict in input_dict.get('nav') for key in
                     key_dict.keys()]
    else:
      flatten_nav= []
    if input_dict.get('panel'):
      flatten_panel = [key for key_dict in input_dict.get('panel') for key in
                       key_dict.keys()]
    else:
      flatten_panel = []
    return {'nav': flatten_nav, 'panel': flatten_panel}
