#
# Cookbook Name:: wt_sync
# Recipe:: default
# Author:: Kendrick Martin
#
# Copyright 2012, Webtrends
#
# All rights reserved - Do Not Redistribute
#
# This recipe installs the needed components to full setup/configure the Search service
#
require 'rest_client'
require 'rexml/document'
require 'json'

if deploy_mode?
	include_recipe "wt_sync::uninstall" 

	# source build
	build_data = data_bag_item('wt_builds', node.chef_environment)
	build_id = build_data[node['wt_sync']['tc_proj'] ]
	if build_id == nil
		raise Chef::Exceptions::AttributeNotFound,
		"could not find build id: #{install_dir}"
	end
	base_url = 'http://teamcity.webtrends.corp/guestAuth/app/rest/builds/' + build_id

	response = RestClient.get base_url
	btID = nil
	build_doc = REXML::Document.new(response.body)
	build_doc.elements.each('//buildType') do |type|
		btID = type.attributes["id"]
	end
	install_url = "http://teamcity.webtrends.corp/guestAuth/repository/download/#{btID}/#{build_id}:id/#{node['wt_sync']['artifact']}"
	log install_url
end
# get parameters
master_host = node['wt_common']['master_host']

# destinations
install_dir = "#{node['wt_common']['install_dir_windows']}#{node['wt_sync']['install_dir']}"

# get data bag items 
auth_data = data_bag_item('authorization', node.chef_environment)
svcuser = auth_data['wt_common']['system_user']
svcpass = auth_data['wt_common']['system_pass']

# determine root drive of install_dir - ENG390500
if (install_dir =~ /^(\w:)\\.*$/)
	install_dir_drive = $1
else
	raise Chef::Exceptions::AttributeNotFound,
		"could not determine install_dir_drive, please verify value of install_dir: #{install_dir}"
end

# create the install directory
directory install_dir do
	recursive true
	action :create
end

directory "#{node['wt_common']['install_dir_windows']}#{node['wt_sync']['log_dir']}" do
	recursive true
	action :create
end


# set permissions for the service user to have read access to the install drive - ENG390500
wt_base_icacls install_dir_drive do
	action :grant
	user svcuser 
	perm :read
end

if deploy_mode?

	# unzip the install package
	windows_zipfile install_dir do
		source install_url
		action :unzip	
	end
	
	template "#{install_dir}\\SyncMessageUtil.exe.config" do
	  source "syncMsgUtilConfig.erb"
	  variables(		
		  :master_host => node['wt_common']['master_host']
	  )
	end
	
	template "#{install_dir}\\Webtrends.SyncService.exe.config" do
	  source "syncServiceConfig.erb"
	  variables(		
		  :master_host => node['wt_common']['master_host'],
		  :cass_host => node['wt_common']['cassandra_host'],
		  :report_column => node['wt_common']['cassandra_report_column'],
		  :thrift_port => node['wt_common']['cassandra_thrift_port'],
		  :metadata_column => node['wt_common']['cassandra_meta_column'],
		  :cache_hosts => node['wt_common']['cache_host'],
		  :cache_region => node['wt_common']['cache_region']
	  )
	end

	powershell "create service" do
		environment({'serviceName' => node['wt_sync']['service_name'], 'serviceBinary' => node['wt_sync']['service_binary'], 'install_dir' => install_dir, 'svcuser' => svcuser, 'svcpass' => svcpass})	
		code <<-EOH
 		# $computer = gc env:computername
 		$class = "Win32_Service"
		$method = "Create"
		# $mc = [wmiclass]"\\\\$computer\\ROOT\\CIMV2:$class"
		$mc = [wmiclass]"\\\\.\\ROOT\\CIMV2:$class"
		$servicePath = $env:install_dir + "\\$env:serviceBinary"
		$inparams = $mc.PSBase.GetMethodParameters($method)
		$inparams.DesktopInteract = $false
		$inparams.DisplayName = $env:serviceName
		$inparams.ErrorControl = 0
		$inparams.LoadOrderGroup = $null
		$inparams.LoadOrderGroupDependencies = $null
		$inparams.Name = $env:serviceName
		$inparams.PathName = $servicePath
		$inparams.ServiceDependencies = $null
		$inparams.ServiceType = 16
		$inparams.StartMode = "Automatic"
		$inparams.StartName = $env:svcuser
		$inparams.StartPassword = $env:svcpass

		$result = $mc.PSBase.InvokeMethod($method,$inparams,$null)
		$result | Format-List
		EOH
	end
	
end

service node['wt_sync']['service_name'] do
	action :start
	ignore_failure true
end