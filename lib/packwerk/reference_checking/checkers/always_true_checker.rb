# typed: strict
# frozen_string_literal: true

module Packwerk
  module ReferenceChecking
    module Checkers
      # Always marks a reference as invalid
      class AlwaysTrueChecker < DependencyChecker
        VIOLATION_TYPE = T.let("always_true", String)

        sig do
          override
            .params(reference: Packwerk::Reference)
            .returns(T::Boolean)
        end
        def invalid_reference?(reference)
          #puts "checking #{reference.inspect}"
          #return false unless reference.package.enforce_dependencies?
          #return false if reference.package.dependency?(reference.constant.package)

          true
        end
      end
    end
  end
end
