module Sequent
  module Core
    module Transactions

      class ActiveRecordTransactionProvider
        def transactional
          Sequent::ApplicationRecord.transaction(requires_new: true) do
            yield
          end
          Sequent.configuration.command_service.set_after_commit_lock
          after_commit_queue.each &:call
        ensure
          clear_after_commit_queue
          Sequent.configuration.command_service.reset_lock_key
        end

        def after_commit(&block)
          after_commit_queue << block
        end

        private

        def after_commit_queue
          Thread.current[:after_commit_queue] ||= []
        end

        def clear_after_commit_queue
          Thread.current[:after_commit_queue] = []
        end
      end

    end
  end
end
