require 'digest/md5'
require 'uri'
require 'appengine-apis/urlfetch'
#require 'appengine-apis/memcache'
require 'java'
require 'json/pure'
import java.lang.System
import org.hokiesuns.guesswhat.model.Quiz
import org.hokiesuns.guesswhat.model.SimpleGuessable
import org.hokiesuns.guesswhat.model.User
import org.hokiesuns.guesswhat.facebook.FacebookWrapper
import org.hokiesuns.guesswhat.facebook.FBUser
import java.util.List
import javax.jdo.Query
import org.hokiesuns.guesswhat.model.Quiz
import org.hokiesuns.guesswhat.model.PMF
import java.lang.Long

require 'appengine-apis/mail'
class Guesswhat < Merb::Controller
  @@FACEBOOK_COOKIE='732394fdee1cd373b6e4898bfb59c16a_session_key'
  before :open_pm, :exclude => [ :get_fbuser,:get_image]
  before :get_fbuser, :exclude => [:get_image]
  before :getQuiz, :exclude => [ :index,:contact,:get_fbuser,:add,:get_image,:user_questions,:my_questions,:question_details]
  after :close_pm, :exclude => [ :get_fbuser,:get_image]
  
  def _template_location(action, type = nil, controller = controller_name)
    controller == "layout" ? "layout.#{action}.#{type}" : "#{action}.#{type}"
  end
  
  def index
    render
  end
  
  def start_quiz
    #Check a user submission
    unless params[:choice].nil?
      userChoice =params[:choice].to_i
      puts "USER CHOICE=#{userChoice} "
      unless @currentQuestion.nil?
        #puts "#{userChoice == @currentQuestion.getCorrectAnswer} CORRECT = #{@currentQuestion.getCorrectAnswer}"
        #Populate the userChoices array if the choice is incorrect. 
        @userChoices[@currentQuestionNumber] = userChoice #@currentQuestion.getAnswers().get(userChoice) if userChoice != @currentQuestion.getCorrectAnswer
        session[:correct_answers] = @userChoices
        @currentQuestionNumber = @currentQuestionNumber+1
        session[:current_question] = @currentQuestionNumber
      end
    end
    if @currentQuestionNumber >= @currentQuiz.size
      redirect "/guesswhat/show_answers" 
    else
      populateQuizInfo
      render
    end    
  end

#  def done_with_quiz
#    @currentQuiz = session[:currentQuiz]
#    if @currentQuiz == nil || !@currentQuiz.isDone
#      redirect "/"
#    else
#      @percentCorrect = @currentQuiz.getCorrectlyGuessed/(@currentQuiz.getNumberQuestions * 1.0)
#      if @fbuid > 0
#        session[:currentQuiz] = nil
#        session[:finishedQuiz]=@currentQuiz
#      end
#      render
#    end
#  end
  
  def show_answers
    if @currentQuestionNumber >= @currentQuiz.size
      #For each question, generate a hash containing the answer image location
      #for display, whether it's correct, the user choice and correct choice
      answers = Quiz.getAnswers(@currentQuiz)
      userAnswers = Quiz.getUserAnswers(@currentQuiz,@userChoices.to_java(:int))
      @displayAnswers = Array.new
      @correctlyGuessed = 0
      answers.each_with_index {|val,idx| 
        is_correct = userAnswers[idx] == val[0]
        @displayAnswers << {:correct_answer => val[0], :answer_image => val[1], :user_answer => userAnswers[idx]}
        @correctlyGuessed = @correctlyGuessed + 1 if is_correct
      }
      #Update statistics
      @currentQuiz.each_with_index {|val,idx|
        Quiz.updateQuestionStatistics(@pm,val,@userChoices[idx])
      }
      session[:quiz_questions] = nil
      session[:current_question] = nil
      session[:correct_answers] = nil      
      render
    else
      redirect "/"
    end
  end
  
  def contact
    if params[:submit] == nil
      render
    else
      AppEngine::Mail.send(params[:emailAddress], "anithian@gmail.com", "GuessWhatItIs Feedback", params[:message])
      render "<div style=\"margin-left:auto;margin-right:auto;width:75%\"><h2>Thank you for your feedback. We read each message and will do our best to personally respond as quickly as possible</h2>.</div>"
    end
  end
  
  def fb_friends
    #Return a list of friends for the YUI autocomplete
    sReturn =""
    query_str=params[:query]
    if !@fbUser.nil? && !query_str.nil? && !query_str.empty?
      query_str.downcase!
      friends = @fbUser.getFriends
      friendids = @fbUser.getFriendIds
      friends.each_with_index {|friend,idx| 
        friendL=friend.downcase
        sReturn << "#{friend},#{friendids[idx]}|" if friendL.index(query_str) == 0
      }
    end
    sReturn
  end
  
  def add
    unless params[:submitQuestion].nil?
      begin
        u=@pm.getObjectById(User.java_class,java::lang::Long.new(@fbuid))
      rescue
        u = User.new @fbuid
        @pm.makePersistent u
      end
      s = SimpleGuessable.new
      s.setImageLocation params[:questionImage]
      s.setAnswerImageLocation params[:answerImage]
      #Loop and get the answer choices accounting for any weird irregularities
      iCorrect = params[:correct].to_i
      iCurrentAnswer = 0
      (0..3).each {|i|
        choice = params["choice#{i}"]
        if choice.length > 0
          s.setCorrectAnswer iCurrentAnswer if i == iCorrect
          s.addAnswer choice
          iCurrentAnswer = iCurrentAnswer + 1
        end
      }
      s.setCreator u
      
      @pm.makePersistent s
    end
    render
  end
  
  def get_image
   imageID = params[:id]
   imageData = ""
   #imageId is a MD5 hash of questionY Y = questionID
   puts "IMAGE ID = #{imageID}"
   currentQuiz = session[:quiz_questions]
   currentQuestion = session[:current_question]
   if currentQuiz != nil && !imageID.nil? && !currentQuestion.nil?
     imageLocation = getQuestionImageLocation(currentQuiz, currentQuestion,imageID)
     imageData = getImageData(request.host, imageLocation)
   end
   send_data imageData, {:disposition=>"inline",:type=>"image/jpg"}   
  end
  
  def user_questions
    provides :json
    content_type :json
    #100000289421407
    q = @pm.newQuery("select from #{SimpleGuessable.java_class.name} where creator==#{@fbuid.to_s}")
    results = q.execute
    questionData = Array.new
    results.each { |question|
      hash={"id"=>question.getId(),"image"=> question.getAnswerImageLocation,"answers"=>question.getAnswers.to_a,"answerDist"=>question.getAnswerDistributions.to_a,"correctAnswer"=>question.getCorrectAnswer}
      questionData << hash
    }
    JSON.generate questionData
  end
  
  def my_questions
    render
  end

  def question_details
    questionId = params[:id]
    if questionId.nil?
      redirect "/"
    else
      begin
        @question=@pm.getObjectById(SimpleGuessable.java_class,java::lang::Long.new(questionId))
        if @question.getCreator != @fbuid
          redirect "/"
        else
          render  
        end
      rescue
        redirect "/"
      end
    end
  end
  private
  
#  def isLoggedIn
#    sessionKey = cookies[@@FACEBOOK_COOKIE]
#    fb_uid = 0
#    if !sessionKey.nil?
#      client = FacebookWrapper.getFacebookJsonRestClient(sessionKey)
#      fb_uid = client.users_getLoggedInUser
#      puts "FB_UID=#{fb_uid}"
#    end
#    fb_uid > 0
#  end

  def getQuestionImageLocation(pCurrentQuiz, pCurrentQuestion,pImageId)
    #1) Generate the MD5 hash of "question<question_id>". If imageId and this hash match, proceed
    #2) Check CACHE to see if an entry for that exists
    #3) if not, go to the DB, look up the question by id and get the image location associate this in the cache
    #4) return the image location
    questionId = pCurrentQuiz[pCurrentQuestion]
    questionHash = Digest::MD5.hexdigest("question#{questionId}")
    if questionHash == pImageId
      imageLocation = CACHE[questionHash]
#      if imageLocation.nil?
#        questionDB = @pm.getObjectById(SimpleGuessable.java_class,Long.new(questionId))
#        imageLocation = questionDB.getImageLocation()
#        CACHE[questionHash] = imageLocation
#      end
      imageLocation
    else
      nil
    end
  end
  
  def getFBClient
    sessionKey = cookies[@@FACEBOOK_COOKIE]
    @fbuid = 0
    if !sessionKey.nil? && sessionKey.length > 0
      puts "Calling wrapper to get client"
      client = FacebookWrapper.getClient(sessionKey)
      begin
        @fbuid = client.users_getLoggedInUser
      rescue Exception => e
        puts "Problem getting current user #{e}"
        cookies[@@FACEBOOK_COOKIE] = nil
        client = nil
      end
      client
    else
      nil
    end
  end
  
  def get_fbuser
    puts "GET FB USER"
    client = getFBClient #Sets @fbuid
    @fbUser = CACHE[@fbuid]
    if !client.nil? && @fbUser.nil?
      puts "CREATING NEW FB USER"
      @fbUser = FBUser.new(@fbuid,client)
      CACHE[@fbuid]=@fbUser
    end
  end
  
  def getImageData(current_host, image_location)
    if image_location.nil?
      return ""
    end
    image_to_dl = image_location
    uri = URI.parse(image_location)
    image_to_dl = "http://#{request.host}/#{image_location}" if uri.scheme != "http"
    res=AppEngine::URLFetch.fetch(image_to_dl)
    res.body
  end
  
  def getQuiz
    quiz_questions = session[:quiz_questions]
    max_quiz_size = 5
    if quiz_questions.nil?
      quiz_questions = Quiz.newQuiz(max_quiz_size)
      session[:quiz_questions] = quiz_questions.to_a
      session[:current_question] = 0
      session[:correct_answers] = Array.new(quiz_questions.size)
    else
      quiz_questions=quiz_questions.to_java(:long)
    end
    @currentQuiz=quiz_questions
    @currentQuestionNumber = session[:current_question]
    populateQuizInfo
  end
  
  def populateQuizInfo
    puts "CURRENT QUESTION = #{@currentQuestionNumber}"
#    @currentQuestion = @currentQuiz.getQuestion(@pm,@currentQuestionNumber)
    if @currentQuestionNumber < @currentQuiz.size
      @currentQuestion = @pm.getObjectById(SimpleGuessable.java_class,Long.new(@currentQuiz[@currentQuestionNumber]))    
      unless @currentQuestion.nil?
        Quiz.getQuestionImageHash(@currentQuiz).each {|key,val| CACHE[key]=val}
        @questionHash = Digest::MD5.hexdigest("question#{@currentQuestion.getId()}")
        @answerList = Array.new
        @currentQuestion.getAnswers().each {|item| @answerList << item}
      end      
    end
    @userChoices = session[:correct_answers]
  end

  def open_pm
    @pm = PMF.get().getPersistenceManager()
  end
  
  def close_pm
    @pm.close unless @pm.nil?
  end
end