$LOAD_PATH.unshift File.dirname(__FILE__) + '/../lib'

require 'optparse'
require 'thread'
require 'monitor'

class Monitor
  alias lock mon_enter
  alias unlock mon_exit
end

module RR
  # This class implements the functionality of the 'replicate' command.
  class ReplicationRunner

    CommandRunner.register 'replicate' => {
      :command => self,
      :description => 'Starts a replication process'
    }
    
    # Provided options. Possible values:
    # * +:config_file+: path to config file
    attr_accessor :options

    # Should be set to +true+ if the replication runner should be terminated.
    attr_accessor :termination_requested

    # Parses the given command line parameter array.
    # Returns the status (as per UNIX conventions: 1 if parameters were invalid,
    # 0 otherwise)
    def process_options(args)
      status = 0
      self.options = {}

      parser = OptionParser.new do |opts|
        opts.banner = <<EOS
Usage: #{$0} replicate [options]

  Replicates two databases as per specified configuration file.
EOS
        opts.separator ""
        opts.separator "  Specific options:"

        opts.on("-c", "--config", "=CONFIG_FILE",
          "Mandatory. Path to configuration file.") do |arg|
          options[:config_file] = arg
        end

        opts.on_tail("--help", "Show this message") do
          $stderr.puts opts
          self.options = nil
        end
      end

      begin
        parser.parse!(args)
        if options # this will be +nil+ if the --help option is specified
          raise("Please specify configuration file") unless options.include?(:config_file)
        end
      rescue Exception => e
        $stderr.puts "Command line parsing failed: #{e}"
        $stderr.puts parser.help
        self.options = nil
        status = 1
      end

      return status
    end

    # Returns the active +Session+.
    # Loads config file and creates session if necessary.
    def session
      unless @session
        RR.logger.debug 'RUNNER - No session exists, creating one now'

        unless @config
          load options[:config_file]
          @config = Initializer.configuration
        end
        @session = Session.new @config

        RR.logger.debug 'RUNNER - Successfully created session'
      end
      @session
    end

    # Removes current +Session+.
    def clear_session
      @session = nil
    end

    # Wait for the next replication time
    def pause_replication
      @last_run ||= 1.year.ago
      now = Time.now
      @next_run = @last_run + Initializer.configuration.options[:replication_interval]
      unless now >= @next_run
        waiting_time = @next_run - now
        @waiter_thread.join waiting_time
      end
      @last_run = Time.now
    end

    # Initializes the waiter thread used for replication pauses and processing
    # the process TERM signal.
    def init_waiter
      @termination_mutex = Monitor.new
      @termination_mutex.lock
      @waiter_thread ||= Thread.new {@termination_mutex.lock; self.termination_requested = true}
      %w(TERM INT).each do |signal|
        Signal.trap(signal) {puts "\nCaught '#{signal}': Initiating graceful shutdown"; @termination_mutex.unlock}
      end
    end

    # Prepares the replication
    def prepare_replication
      initializer = ReplicationInitializer.new session
      initializer.prepare_replication
    end

    # Executes a single replication run
    def execute_once
      session.refresh
      timeout = session.configuration.options[:database_connection_timeout]
      terminated = TaskSweeper.timeout(timeout) do |sweeper|
        run = ReplicationRun.new session, sweeper
        run.run
      end.terminated?

      if terminated
        message = 'RUNNER - Replication run timed out'
        RR.logger.error(message)
        raise message
      end
    end

    # Executes an endless loop of replication runs
    def execute
      init_waiter
      prepare_replication

      until termination_requested do
        begin
          RR.logger.debug 'RUNNER - Starting replication cycle'
          execute_once
          if !@last_run_successfull && !@last_run_successfull.nil?
            RR.logger.info 'RUNNER - Connection successfully established again'
          end
          RR.logger.debug 'RUNNER - Finished replication cycle successfully'
          @last_run_successfull = true
        rescue Exception => e
          # Check if it's a connection problem
          if (e.is_a?(PG::Error) && e.to_s =~ %r/could not connect/) || e.to_s =~ %r/no connection to '(.*)' databases/
            if @last_run_successfull
              RR.logger.error 'RUNNER - Lost connection to one database, terminating session.'
              @last_run_successfull = false
            end
            
            clear_session
            RR.logger.debug 'RUNNER - Databases disconnected, a new one will be built when needed...'
          else
            RR.logger.error("Exception caught: #{e}")
          end
        end
        pause_replication
      end
    end

    # Entry points for executing a processing run.
    # args: the array of command line options that were provided by the user.
    def self.run(args)
      runner = new

      status = runner.process_options(args)
      if runner.options
        runner.execute
      end
      status
    end

  end
end


