#!/usr/bin/env ruby

# AirChat lets you chat to other people nearby who are
# also running AirChat, even if you're not on the same network.
#
# AirChat does this by (ab)using the AirDrop interface.
# It depends on Ruby 2+ and tcpdump, which should exist on
# modern OS X installs.
#
# Usage: [sudo] ./airchat.rb
#
# Cobbled together at Railscamp AU 20 by @chendo
#
#
# Copyright (c) 2016 Jack "chendo" Chen
# Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
# The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

require "readline"
require "securerandom"
require "json"
require "socket"
require "open3"
require "fileutils"
require "timeout"
require "digest/sha1"
require "io/console"

Thread.abort_on_exception = true

class SimpleCurses
  CLEAR_LINE = "\e[2K"
  MOVE_UP    = "\033[1A"
  def initialize
    @mutex = Mutex.new
  end

  def readline(prompt = "> ", hide = true)
    @prompt = prompt
    str = Readline.readline(prompt)
    @last_input = str.chomp
    print "#{MOVE_UP}\r#{CLEAR_LINE}"
    return str
  end

  def redisplay
    # There's a bug in Ruby 2.0 where the Readline.line_buffer isn't cleared on enter
    is_same_line = @last_input == (Readline.line_buffer || "").chomp
    buffer = !is_same_line ? (Readline.line_buffer || "") : ""
    point  = !is_same_line ? Readline.point : 0
    print "\r#{CLEAR_LINE}#{@prompt}#{buffer}#{"\b" * ([buffer.bytesize - point, 0].max)}"
  end

  def puts(str, io = STDOUT)
    @mutex.synchronize do
      io.puts "\r#{CLEAR_LINE}#{str}"
      redisplay
    end
  end

  # Modifies the last line
  def reputs(str, io = STDOUT)
    @mutex.synchronize do
      io.puts "#{MOVE_UP}\r#{CLEAR_LINE}#{str}"
      redisplay
    end
  end
end

class Airchat
  RELIABILITY_FACTOR = 3 # lol
  PING_INTERVAL = 10
  MAX_NICK_LENGTH = 20

  def initialize(port: 1337, preamble: '__AIRCHAT:')
    @ip_to_host = {}
    @port = port
    @preamble = preamble
    @seen_messages = []
    @socket = UDPSocket.new(Socket::AF_INET6)
    @socket.connect('ff02::fb%awdl0', @port)
    @ip_last_seen = {}
    @ip_nick = {}
    @ip_timed_out = {}
    @last_awdl_activity = Time.at(0)
    @simple_curses = SimpleCurses.new
    check_tcpdump_immediate_mode
    @my_ip = `ifconfig awdl0 inet6`.match(/inet6 ([0-9a-f:]+)/)[1]
  end

  def check_tcpdump_immediate_mode
    @immediate_mode = `tcpdump --help 2>&1`["--immediate-mode"]
  end

  def spawn(meth)
    Thread.new(&method(meth))
  end

  def run
    spawn(:listen)
    spawn(:airdrop_activity_monitor)

    puts "Welcome to AirChat.".c(:green)
    puts
    puts "AirChat lets you chat to people nearby without being on the same network.".c(:green)
    puts

    check_permissions
    check_airdrop

    spawn(:airdrop_monitor)
    spawn(:pinger)

    puts
    user = ENV.fetch('HOME').sub('/Users/', '')
    print "Enter a nickname, or leave empty to use #{user.c(:green)}: ".c(:cyan)

    @nick = gets.match(/(\w{0,#{MAX_NICK_LENGTH}})/)[1]
    if @nick.empty?
      @nick = user
    end

    puts

    show_help

    at_exit do
      _, thr = send_msg(:leave)
      thr.join
    end

    _, thr = send_msg(:join)
    thr.join

    show_who

    while true
      line = @simple_curses.readline(prompt_text).chomp

      if line.length > 0
        if line =~ /^\/nick (\w{1,#{MAX_NICK_LENGTH}})/
          send_msg(:nick, new_nick: $1)
          @nick = $1
        elsif line =~ /^\/me (.+)/
          send_msg(:me, action: $1)
        elsif line =~ /^\/(quit|exit)$/
          exit(0)
        elsif line =~ /^\/who$/
          show_who
        elsif line =~ /^\/help$/
          show_help
        elsif line =~ /^\//
          status_output("Unknown command: #{line}".c(:red))
          show_help
        else
          @last_seen_msg_acks = 0
          @last_seen_msg, _ = send_msg(:msg, msg: line)
        end
      end
    end
  end

  def show_who
    status_output("Users (#{@ip_last_seen.count}):")
    @ip_last_seen.each do |ip, time|
      nick = @ip_nick[ip] || "???"
      status_output("  #{colorise_nick(nick, ip)} @ #{ip} - seen #{(Time.now - time).round}s ago")
    end
  end

  def show_help
    status_output("Commands:".c(:cyan))
    status_output("#{'/nick [newnick]'.c(:green)} - #{'changes your nickname'.c(:cyan)}")
    status_output("#{'/who'.c(:green)} - #{'list all users'.c(:cyan)}")
    status_output("#{'/me [action]'.c(:green)} - #{'perform an action'.c(:cyan)}")
    status_output("#{'/quit'.c(:green)} - #{'quits'.c(:cyan)}")
    @simple_curses.puts("[  time  ] [# who saw msg] [nick] [message]".c(:cyan))
  end

  def pinger
    while true
      send_msg(:ping)
      sleep PING_INTERVAL
      lost = []
      @ip_last_seen.each do |ip, time|
        if Time.now - time > (PING_INTERVAL * 3) && @ip_timed_out[ip].nil?
          lost << ip
          @ip_timed_out[ip] = true
        end
      end
      lost.each do |ip|
        nick = @ip_nick[ip] || "???"
        status_output("#{nick} @ #{ip} has timed out")
      end
    end
  end

  def listen
    ip = nil
    len = 0
    buffer = StringIO.new

    Open3.popen3("tcpdump -n #{@immediate_mode} -l -x -i awdl0 udp and port #{@port}") do |i, o, e, t|
      o.each do |line|
        if line =~ /IP6 ([0-9a-f:.]+).+ length (\d+)/
          ip = $1
          len = $2.to_i # This is hex
        elsif line =~ /0x([0-9a-f]{4}):  ([0-9a-f ]+)/
          if $1.to_i(16) >= 0x30 # We only want the UDP data, which starts at 0x0030
            buffer << [$2.gsub(' ', '')].pack("H*")
            if buffer.length > len
              raise "expected buffer length to be #{len} but got #{buffer.length}"
            end
            if buffer.length == len
              handle_message(from: ip, data: buffer.string)
              buffer = StringIO.new
            end
          end
        end
      end
    end
    sleep 2
    raise "Listener exited unexpectedly"
  end

  def open_airdrop_window
    @last_awdl_activity = Time.now
    Open3.popen3("osascript -") do |i, o, e, t|
      i << <<-SCRIPT
        tell application "System Events"
          set frontmostProcess to (path to frontmost application as text)
        end tell
        activate application "Finder"
        tell application "System Events" to keystroke "R" using {command down, shift down}
        activate application frontmostProcess
      SCRIPT
    end
  end

  def airdrop_activity_monitor
    Open3.popen3("tcpdump -n #{@immediate_mode} -l -x -i awdl0 not port #{@port}") do |i, o, e, t|
      o.each do
        @last_awdl_activity = Time.now
      end
    end
    sleep 2
    raise "Airdrop Activity Monitor exited unexpectedly"
  end

  def handle_message(from: nil, data: nil)
    return if @nick.nil? # We're not 'connected'

    if data =~ /^#{@preamble}/
      json = data.sub(@preamble, '')
      msg = Message.parse(json)

      return if msg.nil?

      if @seen_messages.include?(msg.id)
        return
      end

      @seen_messages << msg.id
      while @seen_messages.count > 100
        @seen_messages.delete_at(0)
      end

      nick = msg.from
      cnick = colorise_nick(msg.from, from)
      host = from

      @ip_nick[from] = nick
      @ip_last_seen[from] = Time.now

      if msg.event != 'ack'
        ack, _ = send_msg(:ack, id: msg.id)
        @seen_messages << ack.id
      end

      case msg.event
      when 'join'
        status_output "#{cnick} has joined from #{host}"
      when 'leave'
        status_output "#{cnick} has left (#{host})"
        @ip_nick.delete(from)
        @ip_last_seen.delete(from)
      when 'msg'
        output "   [#{cnick}] #{msg.data}"
        @last_seen_msg = msg
        @last_seen_msg_acks = 0
      when 'me'
        output "   * #{cnick} #{msg.data}"
        @last_seen_msg = msg
        @last_seen_msg_acks = 0
      when 'nick'
        status_output "#{cnick} changed nick to #{msg.data}"
      when 'ping'
        # Covered by 'ack'
      when 'ack'
        if @last_seen_msg && msg.data == @last_seen_msg.id
          @last_seen_msg_acks += 1
          cnick = colorise_nick(@last_seen_msg.from, @my_ip)
          if @last_seen_msg.event == 'me'
            output "%2d * #{cnick} #{@last_seen_msg.data}" % (@last_seen_msg_acks), true
          else
            output "%2d [#{cnick}] #{@last_seen_msg.data}" % (@last_seen_msg_acks), true
          end
        end
      end
    end
  end

  def check_permissions
    Dir["/dev/bpf*"].each do |f|
      FileUtils.touch(f)
    end
  rescue Errno::EPERM, Errno::EACCES
    eputs "AirChat does not have permissions to access the AirDrop interface.".c(:yellow)
    eputs "You can either run AirDrop as root with #{'sudo ./airchat.rb'.c(:green)} or"
    eputs "modify the permissions of #{'/dev/bpf*'.c(:blue)} so your user can access it:"
    eputs "sudo chgrp staff /dev/bpf* && sudo chmod g+rw /dev/bpf*".c(:green)
    eputs "These permission will reset on reboot. If you want to revert them now, run:"
    eputs "sudo chmod g-rw /dev/bpf*".c(:yellow)
    exit 1
  end

  def check_airdrop
    return if ENV['SKIP_CHECK']
    puts "Keep the AirDrop window visible for best results.".c(:yellow)
    print "Checking if AirDrop is running.".c(:yellow)
    begin
      Timeout.timeout(5) do
        while Time.now - @last_awdl_activity > 5
          print ".".c(:yellow)
          sleep 1
        end
        print " "
      end
    rescue Timeout::Error
      print "\n"
      print "AirDrop not running, opening AirDrop window... ".c(:orange)
      open_airdrop_window
    end

    puts "OK".c(:green)
  end

  def airdrop_monitor
    return if ENV['SKIP_CHECK']
    while true
      if Time.now - @last_awdl_activity > 3 * 60
        status_output("No AirDrop activity detected, opening AirDrop window...")
        open_airdrop_window
        @last_awdl_activity = Time.now # so it doesn't pop up all the time
      end
      sleep 5
    end
  end

  def eputs(str)
    @simple_curses.puts(str, STDERR)
  end

  def prompt_text
    "\r[#{@nick.c(:cyan)}] "
  end

  def write(msg)
    @socket.write("#{@preamble}#{msg.to_json}")
  end

  def send_msg(type, **args)
    msg = Message.send(type, **{from: @nick}.merge(args))
    thr = Thread.new do
      RELIABILITY_FACTOR.times do
        write(msg)
        sleep 0.1 # To work around network delay
      end
    end
    [msg, thr]
  end

  def output(line, redisplay = false)
    str = "\r[#{Time.now.strftime("%H:%M:%S")}] #{line}"
    if redisplay
      @simple_curses.reputs str
    else
      @simple_curses.puts str
    end
  end

  def status_output(line)
    output(">> #{line}".c(:orange))
  end

  def colorise_nick(nick, ip_port)
    nick ||= ""
    ip, _ = ip_port.split('.', 2)
    color = Digest::SHA1.digest(ip).chars.map(&:ord).select { |byte| byte > 75 }[0...3]
    nick[0..MAX_NICK_LENGTH].c(color)
  end

  class Message < Struct.new(:id, :from, :event, :data)
    def self.parse(json)
      data = JSON.parse(json)
      id, from, event, data = [:id, :from, :event, :data].map do |key|
        data.fetch(key.to_s)
      end
      new(id, from, event, data)
    rescue => ex
      debug_log(ex)
    end

    def self.create(from: nil, event: nil, data: nil)
      new(SecureRandom.uuid, from, event, data)
    end

    def self.msg(from: nil, msg: nil)
      create(from: from, event: 'msg', data: msg)
    end

    def self.ack(from: nil, id: nil)
      create(from: from, event: 'ack', data: id)
    end

    def self.me(from: nil, action: nil)
      create(from: from, event: 'me', data: action)
    end

    def self.nick(from: nil, new_nick: nil)
      create(from: from, event: 'nick', data: new_nick)
    end

    def self.join(from: nil, data: nil)
      create(from: from, event: 'join')
    end

    def self.leave(from: nil, data: nil)
      create(from: from, event: 'leave')
    end

    def self.ping(from: nil, data: nil)
      create(from: from, event: 'ping')
    end

    def to_json
      JSON.dump({
        id: id,
        from: from,
        event: event,
        data: data
      })
    end
  end
end

def debug_log(msg)
  if ENV['DEBUG']
    eputs msg
  end
end

module ANSIColor
  module_function

  # mostly from Paint gem: https://github.com/janlelis/paint
  def rgb(red, green, blue)
    gray_possible = true
    sep = 42.5

    while gray_possible
      if red < sep || green < sep || blue < sep
        gray = red < sep && green < sep && blue < sep
        gray_possible = false
      end
      sep += 42.5
    end

    if gray
      "\033[38;5;#{ 232 + ((red.to_f + green.to_f + blue.to_f)/33).round }m"
    else # rgb
      "\033[38;5;#{ [16, *[red, green, blue].zip([36, 6, 1]).map{ |color, mod|
        (6 * (color.to_f / 256)).to_i * mod
      }].inject(:+) }m"
    end
  end

  COLOURS = {
    red:    [205, 0,   0],
    yellow: [205, 205, 0],
    blue:   [0,   0,   238],
    green:  [0,   205, 0],
    orange: [205, 120, 0],
    cyan:   [0,   205, 205],
    white:  [229, 229, 229],
  }
  NOTHING = "\033[0m".freeze

  def paint(str, color)
    color = COLOURS[color] || color
    "#{rgb(*color)}#{str}#{NOTHING}"
  end
end

class String
  def c(color)
    ANSIColor.paint(self, color)
  end
end

STDOUT.sync = true

Airchat.new.run

