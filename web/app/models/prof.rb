class Prof < ActiveRecord::Base
  has_many :course_profs
  has_many :courses, :through => :course_profs
  validates_presence_of :firstname, :surname, :gender
  def fullname
    return firstname + ' ' + surname
  end
  def surnamefirst
    return surname + ', ' + firstname
  end
end