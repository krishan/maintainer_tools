require "active_support/core_ext/object/blank"

class Comment

  class Review < Struct.new(:status, :sha)

    def to_s
      "#{status} (#{sha})"
    end

  end

  def initialize(data)
    @data = data
  end

  def data
    @data
  end

  def author
    data['user']['login']
  end

  def status
    extract_status(body)
  end

  def contains_review?
    review.present?
  end

  def review
    extract_review(body)
  end

  def body
    data["body"]
  end

  def pre_ok?
    body =~ /PRE-OK/
  end

  private

  def extract_review(comment_body)
    if comment_body =~ /(FEEDBACK|OK) \(\s*([0-9a-f]{7,40})\s*\)/
      Review.new($1, $2)
    end
  end

  def extract_status(comment_body)
    if comment_body =~ /(REVIEW|FEEDBACK|OK)/
      $1
    end
  end

end
