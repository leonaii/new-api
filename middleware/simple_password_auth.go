package middleware

import (
	"net/http"

	"github.com/gin-contrib/sessions"
	"github.com/gin-gonic/gin"
)

const (
	ModelListPasswordSessionKey = "model_list_password_verified"
	// ModelListPasswordHash 是密码 "pmi@963852741" 的 bcrypt 哈希值
	// 使用 bcrypt 加密存储，提高安全性
	ModelListPasswordHash = "$2a$10$PskNBT4nXcZb0nT8zePm3.HSPA.wIdBAngpFVxh0ybvFoP1WtnHS6"
)

// ModelListPasswordAuth 模型列表密码验证中间件
func ModelListPasswordAuth() gin.HandlerFunc {
	return func(c *gin.Context) {
		session := sessions.Default(c)
		verified := session.Get(ModelListPasswordSessionKey)

		if verified == nil || verified != true {
			c.JSON(http.StatusForbidden, gin.H{
				"success": false,
				"message": "需要密码验证",
				"code":    "PASSWORD_REQUIRED",
			})
			c.Abort()
			return
		}
		c.Next()
	}
}
