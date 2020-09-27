require_relative 'transactions/no_transactions'
require_relative 'current_event'

module Sequent
  module Core
    #
    # Single point in the application to get something done in Sequent.
    # The CommandService handles all subclasses Sequent::Core::BaseCommand. Most common
    # use is to subclass `Sequent::Command`.
    #
    # The CommandService is available via the shortcut method `Sequent.command_service`
    #
    # To use the CommandService please use:
    #
    #   Sequent.command_service.execute_commands(...)
    #
    class CommandService
      #
      # Executes the given commands in a single transactional block as implemented by the +transaction_provider+
      #
      # For each Command:
      #
      # * Validate command
      # * Call Sequent::CommandHandler's listening to the given Command
      # * Store and publish Events
      # * Any new Command's (from e.g. workflows) are queued for processing in the same transaction
      #
      # At the end the transaction is committed and the AggregateRepository's Unit of Work is cleared.
      #
      def execute_commands(*commands)
        commands.each do |command|
          if command.respond_to?(:event_aggregate_id) && CurrentEvent.current
            command.event_aggregate_id = CurrentEvent.current.aggregate_id
            command.event_sequence_number = CurrentEvent.current.sequence_number
          end
        end
        commands.each { |command| command_queue.push(command) }
        process_commands
      end

      def remove_event_handler(clazz)
        warn "[DEPRECATION] `remove_event_handler` is deprecated"
        event_store.remove_event_handler(clazz)
      end

      def reset_lock_key
        Thread.current[:sequent_command_service_lock_key] = :command_service_process_commands
      end

      def set_after_commit_lock
        Thread.current[:sequent_command_service_lock_key] = :sequent_command_service_after_commit_lock_key
      end

      private

      def lock_key
        Thread.current[:sequent_command_service_lock_key] ||= :command_service_process_commands
      end

      def process_commands
        Sequent::Util.skip_if_already_processing(lock_key) do
          begin
            transaction_provider.transactional do
              while(!command_queue.empty?) do
                process_command(command_queue.pop)
              end
            end
          ensure
            command_queue.clear
            repository.clear
          end
        end
      end

      def process_command(command)
        fail ArgumentError, 'command is required' if command.nil?

        Sequent.logger.debug("[CommandService] Processing command #{command.class}")

        filters.each { |filter| filter.execute(command) }

        I18n.with_locale(Sequent.configuration.error_locale_resolver.call) do
          raise CommandNotValid.new(command) unless command.valid?
        end

        parsed_command = command.parse_attrs_to_correct_types
        command_handlers.select { |h| h.class.handles_message?(parsed_command) }.each { |h| h.handle_message parsed_command }
        repository.commit(parsed_command)
      end

      def command_queue
        Thread.current[:command_service_commands] ||= Queue.new
      end

      def event_store
        Sequent.configuration.event_store
      end

      def repository
        Sequent.configuration.aggregate_repository
      end

      def filters
        Sequent.configuration.command_filters
      end

      def transaction_provider
        Sequent.configuration.transaction_provider
      end

      def command_handlers
        Sequent.configuration.command_handlers
      end
    end

    # Raised when BaseCommand.valid? returns false
    class CommandNotValid < ArgumentError
      attr_reader :command

      def initialize(command)
        @command = command
        msg = @command.respond_to?(:aggregate_id) ? " #{@command.aggregate_id}" : ""
        super "Invalid command #{@command.class.to_s}#{msg}, errors: #{@command.validation_errors}"
      end

      def errors(prefix = nil)
        @command.validation_errors(prefix)
      end

      def errors_with_command_prefix
        errors(@command.class.to_s.underscore)
      end
    end
  end
end
