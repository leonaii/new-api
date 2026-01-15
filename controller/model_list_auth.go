package controller

import (
	"net/http"

	"github.com/QuantumNous/new-api/middleware"
	"github.com/gin-contrib/sessions"
	"github.com/gin-gonic/gin"
	"golang.org/x/crypto/bcrypt"
)

type ModelListPasswordRequest struct {
	Password string `json:"password" binding:"required"`
}

// VerifyModelListPassword 验证模型列表密码
func VerifyModelListPassword(c *gin.Context) {
	var req ModelListPasswordRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{
			"success": false,
			"message": "无效的请求",
		})
		return
	}

	// 使用 bcrypt 验证密码哈希
	err := bcrypt.CompareHashAndPassword([]byte(middleware.ModelListPasswordHash), []byte(req.Password))
	if err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{
			"success": false,
			"message": "密码错误",
		})
		return
	}

	// 验证成功，设置 session
	session := sessions.Default(c)
	session.Set(middleware.ModelListPasswordSessionKey, true)
	if err := session.Save(); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{
			"success": false,
			"message": "保存会话失败",
		})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"success": true,
		"message": "验证成功",
	})
}

// CheckModelListPasswordStatus 检查密码验证状态
func CheckModelListPasswordStatus(c *gin.Context) {
	session := sessions.Default(c)
	verified := session.Get(middleware.ModelListPasswordSessionKey)

	c.JSON(http.StatusOK, gin.H{
		"success":  true,
		"verified": verified != nil && verified == true,
	})
}
