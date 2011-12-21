# -*- coding: utf-8-emacs -*-
framework 'Cocoa'
require 'uri'
require 'net/http'
require 'open-uri'
require 'logger'

def main
  app = NSApplication.sharedApplication
  if ARGV.first == '-d'
    app.delegate = GP02Monitor.new :host => 'http://localhost:8001',
      :interval => 15.0, :debug => true
  else
    app.delegate = GP02Monitor.new
  end
  app.run
end

class GP02Monitor
  ROOT_PATH = File.dirname __FILE__
  APP_NAME = 'GP02 Monitor'
  APP_ID = 'org.relucks.gp02monitor'
  ICON_IMG = File.join ROOT_PATH, 'gp02_128x128.png'
  ICON_IMG_ST = File.join ROOT_PATH, 'gp02_16x16.png'
  ICON_IMG_ST_ = File.join ROOT_PATH, 'gp02bc_16x16.png'
  STATUS_CODES = {
    '900' => :connecting,
    '901' => :connected,
    '902' => :disconnected,
    '3' => :disconnecting
  }
  MENU_ITEM_TAGS = [:status, :checked_at, :update_status, :connect, :disconnect,
                    :open_page, :toggle_reconnect, :toggle_disabled, :quit]

  def initialize opt = {}
    @ud = NSUserDefaults.standardUserDefaults
    @config = (@ud.persistentDomainForName(APP_ID) || {}).dup
    @interval = opt[:interval] || 30.0
    @host = opt[:host] || 'http://192.168.1.1'
    @debug = opt[:debug]
    @reconnect = @config.key?('reconnect') ? @config['reconnect'] : true
    @disabled = @config.key?('disabled') ? @config['disabled'] : false
    @growl = Growl.new APP_NAME, ['notification'],
      NSImage.new.initWithContentsOfFile(ICON_IMG)
    @icon_status_ok = NSImage.new.initWithContentsOfFile ICON_IMG_ST
    @icon_status_ng = NSImage.new.initWithContentsOfFile ICON_IMG_ST_
    @menu = NSMenu.new.initWithTitle APP_NAME
    add_menu_items @menu
    @status_item = init_status_bar @menu
    @timer = NSTimer.scheduledTimerWithTimeInterval(@interval,
      target:self, selector:"interval:", userInfo:nil, repeats:true)
    update_status_bar
    interval
  end

  def add_menu_items menu
    menu.addItem create_menu_item 'Status: ...', :status
    menu.addItem create_menu_item 'Checked at: ...', :checked_at
    menu.addItem NSMenuItem.separatorItem
    menu.addItem create_menu_item 'Update Status', :update_status, 'update_status_:'
    menu.addItem create_menu_item 'Connect', :connect, 'try_connect:'
    menu.addItem create_menu_item 'Disconnect', :disconnect, 'try_disconnect:'
    menu.addItem create_menu_item 'Open Setting Page', :open_page, 'open_page:'
    menu.addItem NSMenuItem.separatorItem
    menu.addItem create_menu_item '', :toggle_reconnect, 'toggle_reconnect:'
    menu.addItem create_menu_item '', :toggle_disabled, 'toggle_disabled:'
    menu.addItem NSMenuItem.separatorItem
    menu.addItem create_menu_item 'Quit', :quit, 'quit:'
  end

  def create_menu_item title, tag = nil, action = nil
    menu_item = NSMenuItem.new
    menu_item.title = title
    menu_item.action = action if action
    menu_item.target = self if action
    menu_item.tag = MENU_ITEM_TAGS.index(tag) if tag
    menu_item
  end

  def init_status_bar menu
    status_bar = NSStatusBar.systemStatusBar
    status_item = status_bar.statusItemWithLength NSVariableStatusItemLength
    status_item.setMenu menu
    status_item.setHighlightMode true
    status_item.setImage @icon_status_ng
    status_item
  end

  def interval timer = nil
    return false if @disabled
    st = update_status
    if @reconnect && st == :disconnected
      try_connect
    end
  end

  def update_status timer = nil
    st = get_status
    if @status && @status != st
      logger.info [:change, @status, '>', st]
      @growl.notify st.to_s
    else
      logger.info [:status, st]
    end
    @status = st
    @status_update_at = Time.now
    update_status_bar
    st
  end

  def update_status_bar
    find_menu_item(:status).title = "Status: #{@status.to_s.capitalize}"
    find_menu_item(:checked_at).title = "Checked at: #{@status_update_at && @status_update_at.iso8601}"
    find_menu_item(:toggle_reconnect).title = " #{@reconnect ? '✓' : '  '} Auto Connect"
    find_menu_item(:toggle_disabled).title = " #{@disabled ? '✓' : '  '} Disable Interval Check"

    if @status == :connected
      find_menu_item(:connect).setHidden true
      find_menu_item(:disconnect).setHidden false
      @status_item.setImage @icon_status_ok
    else
      find_menu_item(:connect).setHidden false
      find_menu_item(:disconnect).setHidden true
      @status_item.setImage @icon_status_ng
    end
  end

  def find_menu_item tag
    @menu.itemWithTag MENU_ITEM_TAGS.index(tag)
  end

  def update_status_ sender = nil
    st = update_status
    @growl.notify st.to_s.capitalize
  end

  def try_connect sender = nil
    connect
    check_status
  end

  def try_disconnect sender = nil
    @reconnect = false
    update_status_bar
    disconnect
    check_status
  end

  def open_page sender = nil
    NSWorkspace.sharedWorkspace.openURL NSURL.URLWithString(@host)
  end

  def toggle_reconnect sender = nil
    logger.info [:toggle_reconnect, @reconnect, '>', !@reconnect]
    @reconnect = !@reconnect
    update_config 'reconnect', @reconnect
    update_status_bar
    if @reconnect && @status == :disconnected
      try_connect
    end
  end

  def toggle_disabled sender = nil
    logger.info [:toggle_disabled, @disabled, '>', !@disabled]
    @disabled = !@disabled
    update_config 'disabled', @disabled
    update_status_bar
  end

  def quit sender = nil
    NSApplication.sharedApplication.terminate(self)
  end

  def check_status
    times = 3
    interval = 3.0
    times.times do |i|
      NSTimer.scheduledTimerWithTimeInterval(interval * (i + 1),
      target:self, selector:"update_status:", userInfo:nil, repeats:false)
    end
  end

  def connect
    logger.info [:connect]
    post_action 1
  end

  def disconnect
    logger.info [:disconnect]
    post_action 0
  end

  def post_action val
    uri = URI.parse "#{@host}/api/dialup/dial"
    http = Net::HTTP.new uri.host, uri.port
    http.post(uri.path, '<?xml version="1.0" encoding="utf-8" ?><request><Action>%s</Action></request>' % val)
  end

  def get_status
    url = "#{@host}/api/monitoring/status"
    re = %r(<ConnectionStatus>(\d+)</ConnectionStatus>)
    begin
      s = open(url).read
      code = s.split("\n").map { |i| i.match(re) && i.match(re)[1] }.find {|i| i }
    rescue Exception => e
      logger.error e.inspect
      :error
    else
      STATUS_CODES[code] || :other
    end
  end

  def update_config key, val
    @config[key] = val
    @ud.setPersistentDomain @config, forName:APP_ID
  end

  def logger
    @logger ||= Logger.new(STDOUT)
  end
end

class Growl
  def initialize(app, notifications, icon = nil)
    @application_name = app
    @application_icon = icon || NSApplication.sharedApplication.applicationIconImage
    @notifications = notifications
    @default_notifications = notifications
    @center = NSDistributedNotificationCenter.defaultCenter
    dict = {
      :ApplicationName => @application_name,
      :ApplicationIcon => @application_icon.TIFFRepresentation,
      :AllNotifications => @notifications,
      :DefaultNotifications => @default_notifications
    }
    @center.postNotificationName(:GrowlApplicationRegistrationNotification, object:nil, userInfo:dict, deliverImmediately:true)
  end

  def notify description, title = @application_name
    dict = {
      :ApplicationName => @application_name,
      :NotificationName => @notifications[0],
      :NotificationTitle => title,
      :NotificationDescription => description,
      :NotificationPriority => 0,
      :NotificationIcon => @application_icon.TIFFRepresentation,
    }
    @center.postNotificationName(:GrowlNotification, object:nil, userInfo:dict, deliverImmediately:false)
  end
end

main
